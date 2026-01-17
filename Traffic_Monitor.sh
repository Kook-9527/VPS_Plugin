#!/bin/bash
# ============================================
# 全局流量差值监控 & 端口阻断脚本
# 核心逻辑：
#   1. 监控 指定网卡(如eth0) 的全局 上行/下行 流量。
#   2. 如果 (下载 - 上传) 的差值超过阈值 (说明流量不对称，可能是攻击)。
#   3. 连续多次触发后，使用防火墙阻断 指定端口 (如55555)。
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_BLOCK_PORT=55555           # 要阻断的目标端口
DIFF_THRESHOLD=5                   # 流量差值阈值 (Mbps)
BLOCK_DURATION=300                 # 阻断时间 (秒)
REQUIRED_CONSECUTIVE=60            # 连续异常计数 (秒)
NET_INTERFACE=""                   # 网卡名称 (留空自动检测)

SERVICE_NAME="traffic-monitor.service"
SCRIPT_PATH="/root/check_traffic_loop.sh"
CONFIG_FILE="/etc/traffic_monitor_config.sh"

# =========================
# 加载配置
# =========================
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 自动检测主网卡
if [ -z "$NET_INTERFACE" ]; then
    NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
fi

# 参数初始化
TG_ENABLE=${TG_ENABLE:-"已关闭"}
TG_TOKEN=${TG_TOKEN:-""}
TG_CHATID=${TG_CHATID:-""}
SERVER_NAME=${SERVER_NAME:-"未命名服务器"}
BLOCK_PORT=${BLOCK_PORT:-$DEFAULT_BLOCK_PORT}  # 变量名改为 BLOCK_PORT 以示区分
DIFF_THRESHOLD=${DIFF_THRESHOLD:-20}
BLOCK_DURATION=${BLOCK_DURATION:-300}
REQUIRED_CONSECUTIVE=${REQUIRED_CONSECUTIVE:-3}

install_dependencies() {
    if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO_ID="$ID"; fi
    for cmd in iptables ip6tables curl awk grep; do
        if ! command -v $cmd &>/dev/null; then
            case "$DISTRO_ID" in
                ubuntu|debian) apt update && DEBIAN_FRONTEND=noninteractive apt install -y $cmd ;;
                *) yum install -y $cmd ;;
            esac
        fi
    done
}

save_config() {
    cat << EOF > "$CONFIG_FILE"
TG_ENABLE="$TG_ENABLE"
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
SERVER_NAME="$SERVER_NAME"
BLOCK_PORT="$BLOCK_PORT"
DIFF_THRESHOLD="$DIFF_THRESHOLD"
BLOCK_DURATION="$BLOCK_DURATION"
REQUIRED_CONSECUTIVE="$REQUIRED_CONSECUTIVE"
NET_INTERFACE="$NET_INTERFACE"
EOF
}

# ============================================
# 生成核心监控脚本
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

# 关键变量
TARGET_PORT=\$BLOCK_PORT        # 这里是要被封锁的端口
DIFF_THRESHOLD=$DIFF_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION
REQUIRED_CONSECUTIVE=$REQUIRED_CONSECUTIVE
INTERFACE="$NET_INTERFACE"      # 这里是负责监控的网卡

# 检查网卡
if [ -z "\$INTERFACE" ] || [ ! -d "/sys/class/net/\$INTERFACE" ]; then
    echo "❌ 错误：找不到网卡 \$INTERFACE"
    exit 1
fi

send_tg() {
    [ "\$TG_ENABLE" != "已开启" ] && return
    local status_msg="\$1"
    local time_now=\$(date '+%Y-%m-%d %H:%M:%S')
    local text="🛡️ 名称：\$SERVER_NAME%0A\$status_msg%0A⏰ 时间：\$time_now"
    
    curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \\
        -d "chat_id=\$TG_CHATID" \\
        -d "text=\$text" > /dev/null
}

port_blocked=false
block_start_time=0
HIGH_DIFF_COUNT=0

clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
            # 查找针对目标端口的 DROP 规则
            num=\$([ "\$proto" = "iptables" ] && iptables -L INPUT --line-numbers -n | grep "tcp dpt:\$TARGET_PORT" | grep "DROP" | awk '{print \$1}' | head -n1 || ip6tables -L INPUT --line-numbers -n | grep "tcp dpt:\$TARGET_PORT" | grep "DROP" | awk '{print \$1}' | head -n1)
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
    # 执行阻断：无论攻击来自哪里，直接把这个端口封死
    iptables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
    ip6tables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
    
    echo "\$(date '+%F %T') ⚠️ 全局流量异常 (连续 \$REQUIRED_CONSECUTIVE 次差值 > \${DIFF_THRESHOLD}Mbps)"
    echo "   ↳ 🚫 已执行防御：阻断端口 \$TARGET_PORT"
    send_tg "⚠️ 警告：检测到流量攻击，已阻断端口 \$TARGET_PORT"
    port_blocked=true
    block_start_time=\$(date +%s)
}

unblock_port() {
    clean_rules
    echo "\$(date '+%F %T') ✅ 阻断期结束，解除端口 \$TARGET_PORT 限制"
    send_tg "✅ 恢复：端口 \$TARGET_PORT 已解封"
    port_blocked=false
    block_start_time=0
    HIGH_DIFF_COUNT=0
}

get_bytes() {
    awk -v iface="\$INTERFACE" '\$1 ~ iface":" {print \$2, \$10}' /proc/net/dev | sed 's/:/ /g'
}

while true; do
    if ! \$port_blocked; then
        read rx1 tx1 <<< \$(get_bytes)
        sleep 1
        read rx2 tx2 <<< \$(get_bytes)

        # 计算整机网卡的实时流量差值
        stats=\$(awk -v r1=\$rx1 -v r2=\$rx2 -v t1=\$tx1 -v t2=\$tx2 'BEGIN {
            rx_speed = (r2 - r1) * 8 / 1024 / 1024;
            tx_speed = (t2 - t1) * 8 / 1024 / 1024;
            diff = rx_speed - tx_speed;
            if (diff < 0) diff = -diff;
            printf "%.2f %.2f %.2f", rx_speed, tx_speed, diff
        }')
        
        read rx_mbps tx_mbps diff_mbps <<< "\$stats"

        echo "\$(date '+%F %T') [网卡:\$INTERFACE] ↓下载:\${rx_mbps} | ↑上传:\${tx_mbps} | Δ差值:\${diff_mbps} Mbps"

        is_high=\$(awk -v diff="\$diff_mbps" -v thresh="\$DIFF_THRESHOLD" 'BEGIN {print (diff > thresh) ? 1 : 0}')

        if [ "\$is_high" -eq 1 ]; then
            HIGH_DIFF_COUNT=\$((HIGH_DIFF_COUNT + 1))
            echo "   ↳ ⚠️ 流量差值异常 (\$HIGH_DIFF_COUNT/\$REQUIRED_CONSECUTIVE)"
        else
            HIGH_DIFF_COUNT=0
        fi

        if [ "\$HIGH_DIFF_COUNT" -ge "\$REQUIRED_CONSECUTIVE" ]; then
            block_port
        fi
    else
        now=\$(date +%s)
        elapsed=\$((now - block_start_time))
        if [ "\$elapsed" -ge "\$BLOCK_DURATION" ]; then
            unblock_port
        else
            echo "\$(date '+%F %T') ⏳ 防御生效中(端口 \$TARGET_PORT 已封)，剩余 \$((BLOCK_DURATION - elapsed)) 秒"
            sleep 5
        fi
    fi
done
EOF
    chmod +x "$SCRIPT_PATH"
}

# ============================================
# TG 设置
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
    save_config
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
    fi
    echo "✅ TG 配置已更新"
}

# ============================================
# 修改参数 (已优化文案)
# ============================================
modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "   (直接回车保持默认/当前值)"
    echo "============================="

    read -rp "1. 目标阻断端口 (BLOCK_PORT) - 攻击时封锁此端口 [当前: $BLOCK_PORT]: " input
    BLOCK_PORT=${input:-$BLOCK_PORT}

    read -rp "2. 全局流量差值阈值 Mbps (DIFF_THRESHOLD) [当前: $DIFF_THRESHOLD]: " input
    DIFF_THRESHOLD=${input:-$DIFF_THRESHOLD}

    read -rp "3. 阻断持续时间 秒 (BLOCK_DURATION) [当前: $BLOCK_DURATION]: " input
    BLOCK_DURATION=${input:-$BLOCK_DURATION}

    read -rp "4. 连续异常判断次数 (REQUIRED_CONSECUTIVE) [当前: $REQUIRED_CONSECUTIVE]: " input
    REQUIRED_CONSECUTIVE=${input:-$REQUIRED_CONSECUTIVE}

    read -rp "5. 监控网卡接口 (NET_INTERFACE) [当前: $NET_INTERFACE]: " input
    NET_INTERFACE=${input:-$NET_INTERFACE}

    echo "-----------------------------"
    echo "正在保存并应用新参数..."
    save_config
    create_monitor_script
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        echo "✅ 服务已重启，新参数已生效。"
    else
        echo "✅ 参数已保存。"
    fi
}

# ============================================
# 安装函数
# ============================================
install_monitor() {
    echo "📥 开始安装程序..."
    install_dependencies
    
    echo "此脚本将监控网卡 [$NET_INTERFACE] 的全局流量。"
    read -rp "请输入受到攻击时要阻断的端口 [默认 $BLOCK_PORT]: " USER_PORT
    BLOCK_PORT="${USER_PORT:-$BLOCK_PORT}"

    echo "-----------------------------"
    setup_tg
    echo "-----------------------------"

    create_monitor_script

    cat << EOF > "/etc/systemd/system/$SERVICE_NAME"
[Unit]
Description=Global Traffic Monitor
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
    echo "✅ 安装成功，全网卡监控服务已启动"
}

remove_monitor() {
    echo "🛑 停止服务并清理..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
    # 清理防火墙
    for proto in iptables ip6tables; do
        while true; do
            num=$($proto -L INPUT --line-numbers -n | grep "tcp dpt:$BLOCK_PORT" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            $proto -D INPUT $num
        done
    done

    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH"
    rm -f "$CONFIG_FILE"
    
    TG_ENABLE="已关闭"
    SERVER_NAME="未命名服务器"
    BLOCK_PORT=$DEFAULT_BLOCK_PORT
    DIFF_THRESHOLD=20
    BLOCK_DURATION=300
    REQUIRED_CONSECUTIVE=3
    NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')

    systemctl daemon-reload
    echo "✅ 已完全清理"
}

# ============================================
# 主循环
# ============================================
while true; do
    status_run=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "已运行" || echo "未运行")
    last_block=$(journalctl -u "$SERVICE_NAME" -n 50 2>/dev/null | grep "已执行防御" | tail -n1 | sed 's/.*: //; s/已执行防御.*//' | awk '{print $1,$2,$3}')
    [ -z "$last_block" ] && last_block="无记录"

    clear
    echo "============================="
    echo " 全局流量监控 & 端口阻断脚本 v1.1"
    echo " 功能：整机流量异常 -> 封锁特定端口"
    echo "============================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控网卡：$NET_INTERFACE (所有端口流量)"
    echo "目标阻断：Port $BLOCK_PORT"
    echo "触发条件：差值 > ${DIFF_THRESHOLD}Mbps (持续${REQUIRED_CONSECUTIVE}秒)"
    echo "============================="
    echo "1) 安装并启动监控"
    echo "2) TG通知设置"
    echo "3) 修改脚本参数"
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
