#!/bin/bash
# ============================================
# 智能流量密度监控 & 端口阻断脚本 (滑动窗口版)
# 核心逻辑：
#   1. 维护一个长度为 [WINDOW_DURATION] 秒的时间窗口。
#   2. 每秒检测一次全网卡流量差值。
#   3. 如果过去30秒内，有10次以上差值超过2Mbps，则判定为攻击。
#   4. 触发阻断指定端口 (如 55555)。
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_BLOCK_PORT=55555           # 要阻断的目标端口
DIFF_THRESHOLD=2                   # 流量差值阈值 (Mbps)
BLOCK_DURATION=200                 # 阻断时间 (秒)
WINDOW_DURATION=30                 # 检测时间窗口 (秒)
TRIGGER_COUNT=10                   # 窗口内触发次数阈值
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
BLOCK_PORT=${BLOCK_PORT:-$DEFAULT_BLOCK_PORT}
DIFF_THRESHOLD=${DIFF_THRESHOLD:-$DIFF_THRESHOLD}
BLOCK_DURATION=${BLOCK_DURATION:-$BLOCK_DURATION}
WINDOW_DURATION=${WINDOW_DURATION:-$WINDOW_DURATION}
TRIGGER_COUNT=${TRIGGER_COUNT:-$TRIGGER_COUNT}

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
WINDOW_DURATION="$WINDOW_DURATION"
TRIGGER_COUNT="$TRIGGER_COUNT"
NET_INTERFACE="$NET_INTERFACE"
EOF
}

# ============================================
# 生成核心监控脚本 (滑动窗口逻辑)
# ============================================
create_monitor_script() {
    cat << EOF > "$SCRIPT_PATH"
#!/bin/bash
export LANG=C
export LC_ALL=C

CONFIG_FILE="$CONFIG_FILE"
if [ -f "\$CONFIG_FILE" ]; then source "\$CONFIG_FILE"; fi

TARGET_PORT=\$BLOCK_PORT
INTERFACE="\$NET_INTERFACE"

send_tg() {
    [ "\$TG_ENABLE" != "已开启" ] && return
    local status_msg="\$1"
    local time_now=\$(date '+%Y-%m-%d %H:%M:%S')
    local text="🛡️ 名称：\$SERVER_NAME%0A\$status_msg%0A⏰ 时间：\$time_now"
    curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" -d "chat_id=\$TG_CHATID" -d "text=\$text" > /dev/null
}

clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
            num=\$([ "\$proto" = "iptables" ] && iptables -L INPUT --line-numbers -n | grep "dpt:\$TARGET_PORT" | grep "DROP" | awk '{print \$1}' | head -n1 || ip6tables -L INPUT --line-numbers -n | grep "dpt:\$TARGET_PORT" | grep "DROP" | awk '{print \$1}' | head -n1)
            [ -z "\$num" ] && break
            \$proto -D INPUT \$num
        done
    done
}

get_bytes() {
    awk -v iface="\$INTERFACE" '\$1 ~ iface":" {print \$2, \$10}' /proc/net/dev | sed 's/:/ /g'
}

port_blocked=false
block_start_time=0
history_window=()

while true; do
    # --- 无论是否阻断，每秒都抓取流量 ---
    read rx1 tx1 <<< \$(get_bytes)
    sleep 1
    read rx2 tx2 <<< \$(get_bytes)

    stats=\$(awk -v r1=\$rx1 -v r2=\$rx2 -v t1=\$tx1 -v t2=\$tx2 'BEGIN {
        rx_speed = (r2 - r1) * 8 / 1024 / 1024;
        tx_speed = (t2 - t1) * 8 / 1024 / 1024;
        diff = rx_speed - tx_speed;
        if (diff < 0) diff = -diff;
        printf "%.2f %.2f %.2f", rx_speed, tx_speed, diff
    }')
    read rx_mbps tx_mbps diff_mbps <<< "\$stats"
    is_bad=\$(awk -v diff="\$diff_mbps" -v thresh="\$DIFF_THRESHOLD" 'BEGIN {print (diff > thresh) ? 1 : 0}')

    # 更新滑动窗口
    history_window+=(\$is_bad)
    [ \${#history_window[@]} -gt \$WINDOW_DURATION ] && history_window=("\${history_window[@]:1}")
    total_bad=0
    for val in "\${history_window[@]}"; do total_bad=\$((total_bad + val)); done

    if ! \$port_blocked; then
        # --- 正常监控状态 ---
        echo "\$(date '+%H:%M:%S') [OK] 差值:\${diff_mbps}M | 密度:\${total_bad}/\${WINDOW_DURATION}"
        if [ "\$total_bad" -ge "\$TRIGGER_COUNT" ]; then
            clean_rules
            iptables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
            iptables -A INPUT -p udp --dport \$TARGET_PORT -j DROP
            ip6tables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
            ip6tables -A INPUT -p udp --dport \$TARGET_PORT -j DROP
            echo "\$(date '+%F %T') ⚠️ 触发防御：阻断端口 \$TARGET_PORT"
            send_tg "⚠️ 警告：检测到持续攻击，已阻断端口 \$TARGET_PORT"
            port_blocked=true
            block_start_time=\$(date +%s)
        fi
    else
        # --- 阻断状态 (核心：动态续期逻辑) ---
        now=\$(date +%s)
        elapsed=\$((now - block_start_time))
        remaining=\$((BLOCK_DURATION - elapsed))

        if [ "\$is_bad" -eq 1 ]; then
            # 如果阻断期内依然检测到流量异常，重置计时器
            block_start_time=\$now
            echo "\$(date '+%H:%M:%S') [⚡ 续期] 攻击持续中，阻断时间重置为 \$BLOCK_DURATION 秒"
        else
            echo "\$(date '+%H:%M:%S') [🛡️ 防御] 剩余:\${remaining}s | 当前差值:\${diff_mbps}M"
        fi

        if [ "\$remaining" -le 0 ]; then
            clean_rules
            echo "\$(date '+%F %T') ✅ 攻击停止，解除阻断"
            send_tg "✅ 恢复：攻击停止，端口 \$TARGET_PORT 已解封"
            port_blocked=false
            history_window=() # 清空窗口防止误触发
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
# 修改参数 (已更新为滑动窗口参数)
# ============================================
modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "   (直接回车保持默认/当前值)"
    echo "============================="

    read -rp "1. 目标阻断端口 [当前: $BLOCK_PORT]: " input
    BLOCK_PORT=${input:-$BLOCK_PORT}

    read -rp "2. 流量差值阈值 Mbps [当前: $DIFF_THRESHOLD]: " input
    DIFF_THRESHOLD=${input:-$DIFF_THRESHOLD}
    
    read -rp "3. 检测时间窗口：秒 [当前: $WINDOW_DURATION]: " input
    WINDOW_DURATION=${input:-$WINDOW_DURATION}

    read -rp "4. 窗口内触发次数 [当前: $TRIGGER_COUNT]: " input
    TRIGGER_COUNT=${input:-$TRIGGER_COUNT}

    read -rp "5. 阻断持续时间：秒 [当前: $BLOCK_DURATION]: " input
    BLOCK_DURATION=${input:-$BLOCK_DURATION}

    read -rp "6. 监控网卡接口 [当前: $NET_INTERFACE]: " input
    NET_INTERFACE=${input:-$NET_INTERFACE}

    echo "-----------------------------"
    echo "正在保存并应用新参数..."
    save_config
    create_monitor_script
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
        echo "✅ 服务已重启，新逻辑已生效。"
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
Description=Traffic Monitor (Sliding Window)
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
    echo "✅ 安装成功，智能密度监控已启动"
}

remove_monitor() {
    echo "🛑 停止服务并清理..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
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
    DIFF_THRESHOLD=$DIFF_THRESHOLD
    BLOCK_DURATION=$BLOCK_DURATION
    WINDOW_DURATION=$WINDOW_DURATION
    TRIGGER_COUNT=$TRIGGER_COUNT
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
    echo " 智能流量密度监控 v1.0"
    echo " by：kook9527"
    echo "============================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控网卡：$NET_INTERFACE丨阻断端口：$BLOCK_PORT"
    echo "当前阈值：差值 > ${DIFF_THRESHOLD}Mbps"
    echo "阻断逻辑：${WINDOW_DURATION}秒窗口内出现 > ${TRIGGER_COUNT}次异常"
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
