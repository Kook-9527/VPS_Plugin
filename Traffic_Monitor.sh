#!/bin/bash
# ============================================
# Traffic Monitor 流量差值监控脚本
# 功能：
#   - 监控服务器主网卡的 上传/下载 速率
#   - 当 (上传与下载的速率差值) > 阈值时，判定为异常
#   - 异常持续一定次数后，自动封禁指定端口
#   - 等待一段时间后自动解封
#   - 适用于：代理服务(流量通常对称)、防止单向流量攻击
# ============================================

set -e

# =========================
# 默认参数定义
# =========================
DEFAULT_PORT_VAL=55555             # 阻断监听端口
DIFF_THRESHOLD=5                   # 流量差值阈值 (Mbps)
BLOCK_DURATION=300                 # 阻断时间 (秒)
REQUIRED_CONSECUTIVE=30            # 连续异常计数 (秒)
NET_INTERFACE=""                   # 网卡名称 (留空则自动检测)

SERVICE_NAME="traffic-monitor.service"
SCRIPT_PATH="/root/check_traffic_loop.sh"
CONFIG_FILE="/etc/traffic_monitor_config.sh"

# =========================
# 加载保存的配置
# =========================
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 自动检测网卡 (如果配置为空)
if [ -z "$NET_INTERFACE" ]; then
    NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
fi

# 确保变量有值
TG_ENABLE=${TG_ENABLE:-"已关闭"}
TG_TOKEN=${TG_TOKEN:-""}
TG_CHATID=${TG_CHATID:-""}
SERVER_NAME=${SERVER_NAME:-"未命名服务器"}
PORT=${PORT:-$DEFAULT_PORT_VAL}
DIFF_THRESHOLD=${DIFF_THRESHOLD:-20}
BLOCK_DURATION=${BLOCK_DURATION:-300}
REQUIRED_CONSECUTIVE=${REQUIRED_CONSECUTIVE:-3}

install_dependencies() {
    if [ -f /etc/os-release ]; then . /etc/os-release; DISTRO_ID="$ID"; fi
    # 需要 bc 进行浮点运算 (或者用 awk，这里脚本内部用 awk)
    for cmd in iptables ip6tables curl awk grep; do
        if ! command -v $cmd &>/dev/null; then
            case "$DISTRO_ID" in
                ubuntu|debian) apt update && DEBIAN_FRONTEND=noninteractive apt install -y $cmd ;;
                *) yum install -y $cmd ;;
            esac
        fi
    done
}

# ============================================
# 保存配置函数
# ============================================
save_config() {
    cat << EOF > "$CONFIG_FILE"
TG_ENABLE="$TG_ENABLE"
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
SERVER_NAME="$SERVER_NAME"
PORT="$PORT"
DIFF_THRESHOLD="$DIFF_THRESHOLD"
BLOCK_DURATION="$BLOCK_DURATION"
REQUIRED_CONSECUTIVE="$REQUIRED_CONSECUTIVE"
NET_INTERFACE="$NET_INTERFACE"
EOF
}

# ============================================
# 生成核心监控脚本函数 (流量版)
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

# 变量引入
LOCAL_PORT=\$PORT
DIFF_THRESHOLD=$DIFF_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION
REQUIRED_CONSECUTIVE=$REQUIRED_CONSECUTIVE
INTERFACE="$NET_INTERFACE"

# 确保网卡存在
if [ -z "\$INTERFACE" ] || [ ! -d "/sys/class/net/\$INTERFACE" ]; then
    echo "❌ 错误：找不到网卡 \$INTERFACE"
    exit 1
fi

send_tg() {
    [ "\$TG_ENABLE" != "已开启" ] && return
    local status_msg="\$1"
    local time_now=\$(date '+%Y-%m-%d %H:%M:%S')
    local text="📊 名称：\$SERVER_NAME%0A\$status_msg%0A⏰ 时间：\$time_now"
    
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
    echo "\$(date '+%F %T') ⚠️ 流量异常 (连续 \$REQUIRED_CONSECUTIVE 次差值 > \${DIFF_THRESHOLD}Mbps)，已阻断端口 \$LOCAL_PORT"
    send_tg "⚠️ 警告：流量异常，\$LOCAL_PORT 端口已阻断"
    port_blocked=true
    block_start_time=\$(date +%s)
}

unblock_port() {
    clean_rules
    echo "\$(date '+%F %T') ✅ 阻断时间结束，端口已恢复 \$LOCAL_PORT"
    send_tg "✅ 恢复：\$LOCAL_PORT 端口已解封"
    port_blocked=false
    block_start_time=0
    HIGH_DIFF_COUNT=0
}

# 获取流量函数 (字节)
get_bytes() {
    awk -v iface="\$INTERFACE" '\$1 ~ iface":" {print \$2, \$10}' /proc/net/dev | sed 's/:/ /g'
}

while true; do
    if ! \$port_blocked; then
        # 读取第一次流量
        read rx1 tx1 <<< \$(get_bytes)
        sleep 1
        # 读取第二次流量
        read rx2 tx2 <<< \$(get_bytes)

        # 计算速率 (bps -> Mbps)
        # (Bytes2 - Bytes1) * 8 / 1024 / 1024
        
        # 使用 awk 处理浮点运算，避免整数溢出
        stats=\$(awk -v r1=\$rx1 -v r2=\$rx2 -v t1=\$tx1 -v t2=\$tx2 'BEGIN {
            rx_speed = (r2 - r1) * 8 / 1024 / 1024;
            tx_speed = (t2 - t1) * 8 / 1024 / 1024;
            diff = rx_speed - tx_speed;
            if (diff < 0) diff = -diff;
            printf "%.2f %.2f %.2f", rx_speed, tx_speed, diff
        }')
        
        read rx_mbps tx_mbps diff_mbps <<< "\$stats"

        echo "\$(date '+%F %T') ↓下载: \${rx_mbps} Mbps | ↑上传: \${tx_mbps} Mbps | Δ差值: \${diff_mbps} Mbps"

        # 比较浮点数
        is_high=\$(awk -v diff="\$diff_mbps" -v thresh="\$DIFF_THRESHOLD" 'BEGIN {print (diff > thresh) ? 1 : 0}')

        if [ "\$is_high" -eq 1 ]; then
            HIGH_DIFF_COUNT=\$((HIGH_DIFF_COUNT + 1))
            echo "   ↳ ⚠️ 差值超标 (\$HIGH_DIFF_COUNT/\$REQUIRED_CONSECUTIVE)"
        else
            HIGH_DIFF_COUNT=0
        fi

        if [ "\$HIGH_DIFF_COUNT" -ge "\$REQUIRED_CONSECUTIVE" ]; then
            block_port
        fi
    else
        # 阻断期间倒计时
        now=\$(date +%s)
        elapsed=\$((now - block_start_time))
        if [ "\$elapsed" -ge "\$BLOCK_DURATION" ]; then
            unblock_port
        else
            echo "\$(date '+%F %T') ⏳ 端口已阻断，剩余等待 \$((BLOCK_DURATION - elapsed)) 秒"
            sleep 5
        fi
    fi
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
    save_config
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
    fi
    echo "✅ TG 配置已更新"
}

# ============================================
# 修改运行参数
# ============================================
modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "   (直接回车保持默认/当前值)"
    echo "============================="

    read -rp "1. 监听端口 (PORT) [当前: $PORT]: " input
    PORT=${input:-$PORT}

    read -rp "2. 流量差值阈值 Mbps (DIFF_THRESHOLD) [当前: $DIFF_THRESHOLD]: " input
    DIFF_THRESHOLD=${input:-$DIFF_THRESHOLD}

    read -rp "3. 阻断持续时间 秒 (BLOCK_DURATION) [当前: $BLOCK_DURATION]: " input
    BLOCK_DURATION=${input:-$BLOCK_DURATION}

    read -rp "4. 连续异常判断次数 (REQUIRED_CONSECUTIVE) [当前: $REQUIRED_CONSECUTIVE]: " input
    REQUIRED_CONSECUTIVE=${input:-$REQUIRED_CONSECUTIVE}

    # 允许修改网卡
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
    
    read -rp "请输入监控端口 [默认 $PORT]: " USER_PORT
    PORT="${USER_PORT:-$PORT}"

    echo "-----------------------------"
    setup_tg
    echo "-----------------------------"

    create_monitor_script

    cat << EOF > "/etc/systemd/system/$SERVICE_NAME"
[Unit]
Description=Traffic Monitor Service
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
    echo "✅ 安装成功，流量监控服务已启动"
}

remove_monitor() {
    echo "🛑 停止服务并清理..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    
    # 清理防火墙
    for proto in iptables ip6tables; do
        while true; do
            num=$($proto -L INPUT --line-numbers -n | grep "tcp dpt:$PORT" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            $proto -D INPUT $num
        done
    done

    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH"
    rm -f "$CONFIG_FILE"
    
    TG_ENABLE="已关闭"
    SERVER_NAME="未命名服务器"
    PORT=$DEFAULT_PORT_VAL
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
    last_block=$(journalctl -u "$SERVICE_NAME" -n 50 2>/dev/null | grep "已阻断端口" | tail -n1 | sed 's/.*: //; s/已阻断端口.*//' | awk '{print $1,$2,$3}')
    [ -z "$last_block" ] && last_block="无记录"

    clear
    echo "============================="
    echo " Traffic Monitor 管理脚本 v1.0"
    echo " 功能：流量差值异常自动阻断端口"
    echo "============================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控端口：$PORT丨监控网卡：$NET_INTERFACE"
    echo "最近阻断：$last_block"
    echo "当前阈值：差值 > ${DIFF_THRESHOLD}Mbps / ${BLOCK_DURATION}s / ${REQUIRED_CONSECUTIVE}次"
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
