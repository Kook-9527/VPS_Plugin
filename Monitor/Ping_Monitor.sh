#!/bin/bash
# ============================================
# Ping Monitor 管理脚本
# 功能：
#   - 持续 ping IPv6 目标地址
#   - 延迟异常或中断时封禁端口（IPv4 + IPv6）
#   - 网络恢复并稳定后自动解封
#   - 使用 systemd 常驻运行
#   - 添加 TG 通知设置
#   - 支持动态修改运行参数
# ============================================

set -e

# =========================
# 默认参数定义
# =========================
DEFAULT_PORT_VAL=55555             # 默认监听端口
TARGET_IP="2606:4700:4700::1111"   # 对端IP地址（可填V4）
LATENCY_THRESHOLD=20               # 延迟阈值（ms）
BLOCK_DURATION=120                 # 阻断时间（秒）
REQUIRED_CONSECUTIVE=3             # 连续异常计数

SERVICE_NAME="ping-monitor.service"
SCRIPT_PATH="/root/check_ping_loop.sh"
CONFIG_FILE="/etc/ping_monitor_config.sh"

# =========================
# 加载保存的配置
# =========================
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 确保变量有值（如果没有从配置文件加载到，则使用默认值）
TG_ENABLE=${TG_ENABLE:-"已关闭"}
TG_TOKEN=${TG_TOKEN:-""}
TG_CHATID=${TG_CHATID:-""}
SERVER_NAME=${SERVER_NAME:-"未命名服务器"}
PORT=${PORT:-$DEFAULT_PORT_VAL}
TARGET_IP=${TARGET_IP:-"2606:4700:4700::1111"}
LATENCY_THRESHOLD=${LATENCY_THRESHOLD:-20}
BLOCK_DURATION=${BLOCK_DURATION:-120}
REQUIRED_CONSECUTIVE=${REQUIRED_CONSECUTIVE:-3}

install_dependencies() {
    if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO_ID="$ID"; fi
    for cmd in iptables ip6tables curl; do
        if ! command -v $cmd &>/dev/null; then
            case "$DISTRO_ID" in
                ubuntu|debian) apt update && DEBIAN_FRONTEND=noninteractive apt install -y $cmd ;;
                *) yum install -y $cmd ;;
            esac
        fi
    done
}

# ============================================
# 保存配置函数 (统一管理)
# ============================================
save_config() {
    cat << EOF > "$CONFIG_FILE"
TG_ENABLE="$TG_ENABLE"
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
SERVER_NAME="$SERVER_NAME"
PORT="$PORT"
TARGET_IP="$TARGET_IP"
LATENCY_THRESHOLD="$LATENCY_THRESHOLD"
BLOCK_DURATION="$BLOCK_DURATION"
REQUIRED_CONSECUTIVE="$REQUIRED_CONSECUTIVE"
EOF
}

# ============================================
# 生成核心监控脚本函数
# ============================================
create_monitor_script() {
    cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
export LANG=C
export LC_ALL=C

CONFIG_FILE="$CONFIG_FILE"
if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
fi

# 使用配置中的变量
TARGET_IP="$TARGET_IP"
LOCAL_PORT=\$PORT
LATENCY_THRESHOLD=$LATENCY_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION
REQUIRED_CONSECUTIVE=$REQUIRED_CONSECUTIVE

send_tg() {
    [ "\$TG_ENABLE" != "已开启" ] && return
    local status_msg="\$1"
    local time_now=\$(date '+%Y-%m-%d %H:%M:%S')
    local text="💻 名称：\$SERVER_NAME%0A\$status_msg%0A⏰ 时间：\$time_now"
    
    curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \\
        -d "chat_id=\$TG_CHATID" \\
        -d "text=\$text" > /dev/null
}

port_blocked=false
block_start_time=0
HIGH_LATENCY_COUNT=0

clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
            num=\$([ "\$proto" = "iptables" ] && iptables -L INPUT --line-numbers -n | grep "tcp dpt:\$LOCAL_PORT" | awk '{print \$1}' | head -n1 || ip6tables -L INPUT --line-numbers -n | grep "tcp dpt:\$LOCAL_PORT" | awk '{print \$1}' | head -n1)
            [ -z "\$num" ] && break
            if [ "\$proto" = "iptables" ]; then
                iptables -D INPUT \$num
            else
                ip6tables -D INPUT \$num
            fi
        done
    done
}

block_port() {
    clean_rules
    iptables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
    ip6tables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
    echo "\$(date '+%F %T') ⚠️ 连续 \$REQUIRED_CONSECUTIVE 次异常，已关闭端口 \$LOCAL_PORT"
    send_tg "⚠️ 状态：\$LOCAL_PORT 端口已阻断"
    port_blocked=true
    block_start_time=\$(date +%s)
}

unblock_port() {
    clean_rules
    echo "\$(date '+%F %T') ✅ 阻断时间结束，端口已恢复 \$LOCAL_PORT"
    send_tg "✅ 状态：\$LOCAL_PORT 端口已恢复"
    port_blocked=false
    block_start_time=0
    HIGH_LATENCY_COUNT=0
}

while true; do
    ping_output=\$(ping -6 -c 1 -W 1 \$TARGET_IP 2>/dev/null)
    latency=\$(echo "\$ping_output" | grep "time=" | sed -E 's/.*time=([0-9.]+).*/\1/')

    if ! \$port_blocked; then
        if [ -z "\$latency" ]; then
            HIGH_LATENCY_COUNT=\$((HIGH_LATENCY_COUNT + 1))
            echo "\$(date '+%F %T') ❌ ping 失败（连续 \$HIGH_LATENCY_COUNT/\$REQUIRED_CONSECUTIVE）"
        else
            latency_int=\${latency%.*}
            echo "\$(date '+%F %T') 延迟 \${latency}ms"
            if [ "\$latency_int" -ge "\$LATENCY_THRESHOLD" ]; then
                HIGH_LATENCY_COUNT=\$((HIGH_LATENCY_COUNT + 1))
                echo "\$(date '+%F %T') ⚠️ 高延迟计数 \$HIGH_LATENCY_COUNT/\$REQUIRED_CONSECUTIVE"
            else
                HIGH_LATENCY_COUNT=0
            fi
        fi

        if [ "\$HIGH_LATENCY_COUNT" -ge "\$REQUIRED_CONSECUTIVE" ]; then
            block_port
        fi
    else
        现在=\$(date +%s)
        elapsed=\$((now - block_start_time))
        if [ "\$elapsed" -ge "\$BLOCK_DURATION" ]; then
            unblock_port
        else
            echo "\$(date '+%F %T') ⏳ 端口已阻断，剩余等待 \$((BLOCK_DURATION - elapsed)) 秒"
        fi
    fi
    sleep 5
done
EOF
    chmod +x "$SCRIPT_PATH"
}

# ============================================
# TG 设置函数
# ============================================
setup_tg() {
    echo "--- TG 通知配置 ---"
    read -rp "是否开启 TG 通知? [Y/n]: " choice
    choice=${choice:-y}
    if [[ "$choice" == [yY] ]]; then
        read -rp "请输入此服务器备注名称: " SERVER_NAME
        read -rp "请输入TG机器人Token: " TG_TOKEN
        read -rp "请输入TG账号ID: " TG_CHATID
        TG_ENABLE="已开启"
    else
        TG_ENABLE="已关闭"
    fi
    
    save_config # 保存所有配置

    # 如果服务在运行，立即重启
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
    fi
    echo "✅ TG 配置已更新"
}

# ============================================
# 修改运行参数 (新增功能)
# ============================================
modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "   (直接回车保持默认/当前值)"
    echo "============================="

    # 1. 监听端口
    read -rp "1. 监听端口 [当前: $PORT]: " input
    PORT=${input:-$PORT}

    # 2. 目标IP
    read -rp "2. 目标IP (IPv4/IPv6) [当前: $TARGET_IP]: " input
    TARGET_IP=${input:-$TARGET_IP}

    # 3. 延迟阈值
    read -rp "3. 延迟阈值(ms) [当前: $LATENCY_THRESHOLD]: " input
    LATENCY_THRESHOLD=${input:-$LATENCY_THRESHOLD}

    # 4. 阻断时间
    read -rp "4. 阻断时间(秒) [当前: $BLOCK_DURATION]: " input
    BLOCK_DURATION=${input:-$BLOCK_DURATION}

    # 5. 连续异常次数
    read -rp "5. 连续异常次数 [当前: $REQUIRED_CONSECUTIVE]: " input
    REQUIRED_CONSECUTIVE=${input:-$REQUIRED_CONSECUTIVE}

    echo "-----------------------------"
    echo "正在保存并应用新参数..."
    
    save_config         # 保存配置到文件
    create_monitor_script # 重新生成后台脚本文件

    # 重启服务
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        echo "✅ 服务已重启，新参数已生效。"
    else
        echo "✅ 参数已保存 (服务未运行，启动后生效)。"
    fi
}

# ============================================
# 安装函数
# ============================================
install_monitor() {
    echo "📥 开始安装程序..."
    install_dependencies
    
    # 1. 询问端口 (支持回车默认)
    read -rp "请输入监控端口 [默认 $PORT]: " USER_PORT
    PORT="${USER_PORT:-$PORT}"

    # 2. 进入 TG 配置
    echo "-----------------------------"
    setup_tg
    echo "-----------------------------"

    # 3. 生成后台脚本 (使用当前所有参数)
    create_monitor_script

    # 4. 创建 Systemd 服务
    cat << EOF > "/etc/systemd/system/$SERVICE_NAME"
[Unit]
Description=Ping Monitor
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH
Restart=always
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    echo "✅ 安装成功，服务已启动"
}

remove_monitor() {
    echo "🛑 停止服务并清理..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
    for proto in iptables ip6tables; do
        while true; do
            num=$($proto -L INPUT --line-numbers -n | grep "tcp dpt:$PORT" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            $proto -D INPUT $num
        done
    done

    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH"
    rm -f "$CONFIG_FILE"
    
    # 重置变量为默认
    TG_ENABLE="已关闭"
    SERVER_NAME="未命名服务器"
    PORT=$DEFAULT_PORT_VAL
    TARGET_IP="2606:4700:4700::1111"
    LATENCY_THRESHOLD=20
    BLOCK_DURATION=120
    REQUIRED_CONSECUTIVE=3

    systemctl daemon-reload
    echo "✅ 已完全清理"
}

# ============================================
# 主循环
# ============================================
while true; do
    status_run=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "已运行" || echo "未运行")
    last_block=$(journalctl -u "$SERVICE_NAME" -n 50 2>/dev/null | grep "已关闭端口" | tail -n1 | sed 's/.*: //; s/已关闭端口.*//' | awk '{print $1,$2,$3}')
    [ -z "$last_block" ] && last_block="无记录"

    clear
    echo "=============================================="
    echo " Ping Monitor 管理脚本 v1.0.2 | by：Kook9527"
    echo "=============================================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控端口：$PORT丨最近阻断：$last_block"
    echo "当前阈值：连续${REQUIRED_CONSECUTIVE}次超过${LATENCY_THRESHOLD}ms会阻断，然后${BLOCK_DURATION}秒后恢复"
    echo "============================="
    echo "1) 安装并启动监控"
    echo "2) TG通知设置"
    echo "3) 修改运行参数"
    echo "4) 清理并复原"
    echo "0) 退出"
    echo "============================="
    read -rp "请输入选项 [0-4]: " choice
    case "$choice" in
        1) install_monitor ;;
        2) setup_tg ;;
        3) modify_params ;;
        4) remove_monitor ;;
        0) exit 0 ;;
    esac
    read -p "按回车返回菜单..." 
done
