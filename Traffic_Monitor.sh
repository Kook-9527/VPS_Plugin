#!/bin/bash
# ============================================
# 智能流量密度监控 & 端口阻断脚本 (滑动窗口版)
# 核心逻辑：
#   1. 维护一个长度为 [WINDOW_DURATION] 秒的时间窗口。
#   2. 每秒检测一次全网卡流量差值。
#   3. 如果过去 60秒 内，有 40次 以上差值超过 3Mbps，则判定为攻击。
#   4. 触发阻断指定端口 (如 55555)。
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_BLOCK_PORT=55555           # 要阻断的目标端口
DIFF_THRESHOLD=2                   # 流量差值阈值 (Mbps)
BLOCK_DURATION=280                 # 阻断时间 (秒)
WINDOW_DURATION=60                 # 检测时间窗口 (秒)
TRIGGER_COUNT=30                   # 窗口内触发次数阈值
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
DIFF_THRESHOLD=${DIFF_THRESHOLD:-3}
BLOCK_DURATION=${BLOCK_DURATION:-300}
WINDOW_DURATION=${WINDOW_DURATION:-60}
TRIGGER_COUNT=${TRIGGER_COUNT:-40}

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
if [ -f "\$CONFIG_FILE" ]; then
    source "\$CONFIG_FILE"
fi

# 关键变量
TARGET_PORT=\$BLOCK_PORT
DIFF_THRESHOLD=$DIFF_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION
WINDOW_DURATION=$WINDOW_DURATION
TRIGGER_COUNT=$TRIGGER_COUNT
INTERFACE="$NET_INTERFACE"

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

# 初始化滑动窗口数组
history_window=()

clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
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
    iptables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
    ip6tables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
    
    echo "\$(date '+%F %T') ⚠️ 密度检测报警 (近 \$WINDOW_DURATION 秒内有 \$total_bad 次异常)"
    echo "   ↳ 🚫 已执行防御：阻断端口 \$TARGET_PORT"
    send_tg "⚠️ 警告：检测到持续攻击 (密度 \$total_bad/\$WINDOW_DURATION)，已阻断端口 \$TARGET_PORT"
    port_blocked=true
    block_start_time=\$(date +%s)
    # 清空历史，避免刚解封又触发
    history_window=()
}

unblock_port() {
    clean_rules
    echo "\$(date '+%F %T') ✅ 阻断期结束，解除端口 \$TARGET_PORT 限制"
    send_tg "✅ 恢复：端口 \$TARGET_PORT 已解封"
    port_blocked=false
    block_start_time=0
    history_window=()
}

get_bytes() {
    awk -v iface="\$INTERFACE" '\$1 ~ iface":" {print \$2, \$10}' /proc/net/dev | sed 's/:/ /g'
}

while true; do
    if ! \$port_blocked; then
        read rx1 tx1 <<< \$(get_bytes)
        sleep 1
        read rx2 tx2 <<< \$(get_bytes)

        # 1. 计算当前这一秒的状态
        stats=\$(awk -v r1=\$rx1 -v r2=\$rx2 -v t1=\$tx1 -v t2=\$tx2 'BEGIN {
            rx_speed = (r2 - r1) * 8 / 1024 / 1024;
            tx_speed = (t2 - t1) * 8 / 1024 / 1024;
            diff = rx_speed - tx_speed;
            if (diff < 0) diff = -diff;
            printf "%.2f %.2f %.2f", rx_speed, tx_speed, diff
        }')
        
        read rx_mbps tx_mbps diff_mbps <<< "\$stats"

        # 判断这一秒是否“坏” (超过阈值)
        is_bad=\$(awk -v diff="\$diff_mbps" -v thresh="\$DIFF_THRESHOLD" 'BEGIN {print (diff > thresh) ? 1 : 0}')
        
        # 2. 加入滑动窗口 (记录历史)
        history_window+=(\$is_bad)
        
        # 3. 保持窗口大小不超过设定值 (比如60)
        if [ \${#history_window[@]} -gt \$WINDOW_DURATION ]; then
            # 删除数组第一个元素 (最早的记录)
            history_window=("\${history_window[@]:1}")
        fi
        
        # 4. 统计窗口内的坏秒数
        total_bad=0
        for val in "\${history_window[@]}"; do
            total_bad=\$((total_bad + val))
        done

        # 显示状态
        if [ "\$is_bad" -eq 1 ]; then
            bad_mark="[⚠️ 异常]"
        else
            bad_mark="[OK]"
        fi
        echo "\$(date '+%F %T') \$bad_mark 差值:\${diff_mbps}Mbps | 密度: \${total_bad}/\${WINDOW_DURATION}"

        # 5. 触发判断
        if [ "\$total_bad" -ge "\$TRIGGER_COUNT" ]; then
            block_port
        fi
    else
        # 阻断中...
        now=\$(date +%s)
        elapsed=\$((now - block_start_time))
        if [ "\$elapsed" -ge "\$BLOCK_DURATION" ]; then
            unblock_port
        else
            echo "\$(date '+%F %T') ⏳ 防御生效中，剩余 \$((BLOCK_DURATION - elapsed)) 秒"
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
# 修改参数 (已更新为滑动窗口参数)
# ============================================
modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "   (直接回车保持默认/当前值)"
    echo "============================="

    read -rp "1. 目标阻断端口 (BLOCK_PORT) [当前: $BLOCK_PORT]: " input
    BLOCK_PORT=${input:-$BLOCK_PORT}

    read -rp "2. 流量差值阈值 Mbps (DIFF_THRESHOLD) [当前: $DIFF_THRESHOLD]: " input
    DIFF_THRESHOLD=${input:-$DIFF_THRESHOLD}
    
    read -rp "3. 检测时间窗口 秒 (WINDOW_DURATION) [当前: $WINDOW_DURATION]: " input
    WINDOW_DURATION=${input:-$WINDOW_DURATION}

    read -rp "4. 窗口内触发次数 (TRIGGER_COUNT) [当前: $TRIGGER_COUNT]: " input
    TRIGGER_COUNT=${input:-$TRIGGER_COUNT}

    read -rp "5. 阻断持续时间 秒 (BLOCK_DURATION) [当前: $BLOCK_DURATION]: " input
    BLOCK_DURATION=${input:-$BLOCK_DURATION}

    read -rp "6. 监控网卡接口 (NET_INTERFACE) [当前: $NET_INTERFACE]: " input
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
    DIFF_THRESHOLD=3
    BLOCK_DURATION=300
    WINDOW_DURATION=60
    TRIGGER_COUNT=40
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
    echo " 智能流量密度监控 v2.0"
    echo " 逻辑：${WINDOW_DURATION}秒窗口内出现 > ${TRIGGER_COUNT}次异常"
    echo "============================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控网卡：$NET_INTERFACE"
    echo "目标阻断：Port $BLOCK_PORT"
    echo "当前阈值：差值 > ${DIFF_THRESHOLD}Mbps"
    echo "============================="
    echo "1) 安装并启动监控"
    echo "2) TG通知设置"
    echo "3) 修改参数 (端口/阈值/窗口/次数)"
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
