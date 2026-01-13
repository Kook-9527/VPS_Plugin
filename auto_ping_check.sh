#!/bin/bash
# ============================================
# Ping Monitor 管理脚本（IPv4 + IPv6 双栈，支持交互式端口输入）
# 功能：
#   - 持续 ping IPv6 目标地址
#   - 延迟异常或中断时封禁端口（IPv4 + IPv6）
#   - 网络恢复并稳定后自动解封
#   - 使用 systemd 常驻运行
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_PORT=55555                   # 默认监听端口
TARGET_IP="2606:4700:4700::1111"     # IPv6 对端地址
LATENCY_THRESHOLD=50                 # 延迟阈值（ms）
BLOCK_DURATION=300                   # 阻断最短时间（秒）

SERVICE_NAME="ping-monitor.service"
SCRIPT_PATH="/root/check_ping_loop.sh"

# ============================================
# 自动检测 Linux 发行版
# ============================================
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="$ID"
        DISTRO_LIKE="$ID_LIKE"
    else
        echo "❌ 无法检测 Linux 发行版"
        exit 1
    fi
}

# ============================================
# 自动安装 iptables / ip6tables
# ============================================
install_iptables() {
    detect_distro

    if ! command -v iptables &>/dev/null; then
        echo "📦 未检测到 iptables，开始安装..."
        case "$DISTRO_ID" in
            ubuntu|debian)
                apt update
                DEBIAN_FRONTEND=noninteractive apt install -y iptables
                ;;
            centos|rocky|almalinux|rhel)
                yum install -y iptables
                ;;
            *)
                echo "❌ 不支持的发行版，请手动安装 iptables"
                exit 1
                ;;
        esac
    fi

    if ! command -v ip6tables &>/dev/null; then
        echo "📦 未检测到 ip6tables，开始安装..."
        case "$DISTRO_ID" in
            ubuntu|debian)
                apt update
                DEBIAN_FRONTEND=noninteractive apt install -y iptables
                ;;
            centos|rocky|almalinux|rhel)
                yum install -y iptables
                ;;
            *)
                echo "❌ 不支持的发行版，请手动安装 ip6tables"
                exit 1
                ;;
        esac
    fi

    echo "✅ iptables / ip6tables 已就绪"
}

# ============================================
# 安装监控服务（支持交互式端口输入）
# ============================================
install_monitor() {
    echo "📥 开始安装 ping-monitor..."

    install_iptables

    # 交互式输入端口
    read -rp "请输入要监控的端口 [默认 $DEFAULT_PORT]: " USER_PORT
    if [[ -z "$USER_PORT" ]]; then
        PORT="$DEFAULT_PORT"
    else
        PORT="$USER_PORT"
    fi

    echo "⚙️ 监控端口设置为: $PORT"

    # ----------------------------
    # 写入实际运行的监控脚本
    # ----------------------------
    cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
export LANG=C
export LC_ALL=C

TARGET_IP="$TARGET_IP"
LOCAL_PORT=$PORT
LATENCY_THRESHOLD=$LATENCY_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION

port_blocked=false
block_start_time=0

clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
            num=\$($proto -L INPUT --line-numbers -n | grep "tcp dpt:\$LOCAL_PORT" | awk '{print \$1}' | head -n1)
            [ -z "\$num" ] && break
            \$proto -D INPUT \$num
        done
    done
}

is_port_blocked() {
    iptables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null || \
    ip6tables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null
}

block_port() {
    if ! is_port_blocked; then
        clean_rules
        iptables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
        ip6tables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
        echo "\$(date '+%F %T') ⚠️ 延迟超过 \${LATENCY_THRESHOLD}ms 或无法 ping，已关闭端口 \$LOCAL_PORT"
        port_blocked=true
        block_start_time=\$(date +%s)
    fi
}

unblock_port() {
    if is_port_blocked; then
        clean_rules
        iptables -A INPUT -p tcp --dport \$LOCAL_PORT -j ACCEPT
        ip6tables -A INPUT -p tcp --dport \$LOCAL_PORT -j ACCEPT
        echo "\$(date '+%F %T') ✅ 延迟恢复正常，已开放端口 \$LOCAL_PORT"
        port_blocked=false
        block_start_time=0
    fi
}

while true; do
    ping_output=\$(ping -6 -c 1 -W 1 \$TARGET_IP 2>/dev/null)
    latency=\$(echo "\$ping_output" | grep "time=" | sed -E 's/.*time=([0-9.]+).*/\1/')

    if [ -z "\$latency" ]; then
        echo "\$(date '+%F %T') ❌ 无法 ping 通 \$TARGET_IP"
        block_port
    else
        latency_int=\${latency%.*}
        echo "\$(date '+%F %T') ℹ️ 延迟 \${latency}ms"

        if \$port_blocked; then
            now=\$(date +%s)
            elapsed=\$((now - block_start_time))
            if [ \$elapsed -ge \$BLOCK_DURATION ]; then
                if [ "\$latency_int" -lt "\$LATENCY_THRESHOLD" ]; then
                    unblock_port
                else
                    echo "\$(date '+%F %T') ⏳ 延迟仍高于 \${LATENCY_THRESHOLD}ms，继续阻断端口"
                fi
            else
                echo "\$(date '+%F %T') ⏳ 端口已阻断，剩余等待 \$((BLOCK_DURATION - elapsed)) 秒"
            fi
        else
            if [ "\$latency_int" -ge "\$LATENCY_THRESHOLD" ]; then
                block_port
            fi
        fi
    fi

    sleep 5
done
EOF

    chmod +x "$SCRIPT_PATH"

    # ----------------------------
    # systemd 服务文件
    # ----------------------------
    cat << EOF > "/etc/systemd/system/$SERVICE_NAME"
[Unit]
Description=Ping Monitor - Auto Close Port $PORT (IPv4 + IPv6)
After=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    echo "✅ 安装完成：服务已启动 (systemctl status $SERVICE_NAME 查看状态)"
}

# ============================================
# 清理服务和规则（改为按行号彻底删除）
# ============================================
remove_monitor() {
    echo "🛑 停止并清理服务..."

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload

    rm -f "$SCRIPT_PATH"

    echo "🧹 清理 iptables / ip6tables 规则..."
    for proto in iptables ip6tables; do
        while true; do
            num=$($proto -L INPUT --line-numbers -n | grep "tcp dpt:$PORT" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            $proto -D INPUT $num
        done
    done

    echo "✅ 已完全清理并复原"
}

# ============================================
# 交互菜单
# ============================================
show_menu() {
    echo "============================="
    echo " Ping Monitor 管理脚本"
    echo "============================="
    echo "1) 安装并启动监控"
    echo "2) 清理并复原"
    echo "0) 退出"
    echo "============================="
    read -rp "请输入选项 [0-2]: " choice

    case "$choice" in
        1) install_monitor ;;
        2) remove_monitor ;;
        0) exit 0 ;;
        *) echo "无效输入" ;;
    esac
}

# ============================================
# 脚本入口
# ============================================
if [ -n "$1" ]; then
    case "$1" in
        1) install_monitor ;;
        2) remove_monitor ;;
        *) echo "用法: $0 {1|2}" ;;
    esac
else
    show_menu
fi
