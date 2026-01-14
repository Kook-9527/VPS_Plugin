#!/bin/bash
# ============================================
# Ping Monitor 管理脚本 v1.1.1
# 功能：
# - 持续 ping IPv6 目标地址
# - 延迟异常或中断时封禁端口（IPv4 + IPv6）
# - 网络恢复并稳定后自动解封
# - 使用 systemd 常驻运行
# - 菜单显示状态、端口、最近阻断
# - TG通知可选，自定义服务器备注
# - TG 消息多行排版：名称 / 状态 / 时间
# - 清理彻底，systemd稳定
# ============================================

# --------------------------
# 原始参数
# --------------------------
DEFAULT_PORT=55555                   # 默认监听端口
TARGET_IP="2606:4700:4700::1111"     # 对端IP地址（可填V4）
LATENCY_THRESHOLD=10                 # 延迟阈值（ms）
BLOCK_DURATION=120                   # 阻断时间（秒）
REQUIRED_CONSECUTIVE=3               # 连续3次ping值超过默认就阻断

SERVICE_NAME="ping-monitor.service"
SCRIPT_PATH="/root/check_ping_loop.sh"
LAST_BLOCK_FILE="/root/ping_monitor_last_block.txt"

# ============================================
# 状态读取
# ============================================
get_service_status() {
    systemctl is-active --quiet "$SERVICE_NAME" && echo "运行中" || echo "关闭"
}

get_tg_status() {
    [ -f "$SCRIPT_PATH" ] && grep -q "^TG_ENABLE=1" "$SCRIPT_PATH" && echo "运行中" || echo "关闭"
}

get_monitor_port() {
    [ -f "$SCRIPT_PATH" ] && grep "^LOCAL_PORT=" "$SCRIPT_PATH" | cut -d= -f2 || echo "-"
}

get_last_block_time() {
    [ -f "$LAST_BLOCK_FILE" ] && cat "$LAST_BLOCK_FILE" || echo "无"
}

# ============================================
# TG 设置
# ============================================
tg_settings() {
    [ ! -f "$SCRIPT_PATH" ] && echo "❌ 服务未安装" && return

    TG_ENABLE=$(grep "^TG_ENABLE=" "$SCRIPT_PATH" | cut -d= -f2)
    if [ "$TG_ENABLE" != "1" ]; then
        read -rp "是否启用 Telegram 通知？[Y/n]: " c
        if [[ -z "$c" || "$c" =~ ^[Yy]$ ]]; then
            read -rp "请输入 TG Bot Token: " token
            read -rp "请输入 TG Chat ID: " chat
            read -rp "请输入本服务器备注（如 小鸡1）: " SERVER_NAME
            SERVER_NAME="${SERVER_NAME:-未命名服务器}"
            sed -i "s/^TG_ENABLE=.*/TG_ENABLE=1/" "$SCRIPT_PATH"
            sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$token\"|" "$SCRIPT_PATH"
            sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$chat\"|" "$SCRIPT_PATH"
            sed -i "s|^SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|" "$SCRIPT_PATH"
        fi
    else
        echo "1) 修改 TG 配置"
        echo "2) 关闭 TG 通知"
        echo "0) 返回"
        read -rp "请选择: " sub
        case "$sub" in
            1)
                read -rp "新的 TG机器人 Token: " token
                read -rp "新的 TG账号 ID: " chat
                read -rp "新的服务器备注: " SERVER_NAME
                SERVER_NAME="${SERVER_NAME:-未命名服务器}"
                sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$token\"|" "$SCRIPT_PATH"
                sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$chat\"|" "$SCRIPT_PATH"
                sed -i "s|^SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|" "$SCRIPT_PATH"
                ;;
            2)
                sed -i "s/^TG_ENABLE=.*/TG_ENABLE=0/" "$SCRIPT_PATH"
                ;;
        esac
    fi

    systemctl restart "$SERVICE_NAME"
    echo "✅ TG 设置已更新"
}

# ============================================
# 安装监控
# ============================================
install_monitor() {
    read -rp "请输入监控端口 [默认 $DEFAULT_PORT]: " p
    PORT="${p:-$DEFAULT_PORT}"

    read -rp "是否启用 Telegram 通知？[Y/n]: " c
    if [[ -z "$c" || "$c" =~ ^[Yy]$ ]]; then
        TG_ENABLE=1
        read -rp "TG机器人 Token: " TG_BOT_TOKEN
        read -rp "TG账号 ID: " TG_CHAT_ID
        read -rp "请输入本服务器备注（如 小鸡1）: " SERVER_NAME
        SERVER_NAME="${SERVER_NAME:-未命名服务器}"
    else
        TG_ENABLE=0
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        SERVER_NAME="未命名服务器"
    fi

cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
TARGET_IP="$TARGET_IP"
LOCAL_PORT=$PORT
LATENCY_THRESHOLD=$LATENCY_THRESHOLD
BLOCK_DURATION=$BLOCK_DURATION
REQUIRED_CONSECUTIVE=$REQUIRED_CONSECUTIVE

TG_ENABLE=$TG_ENABLE
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SERVER_NAME="$SERVER_NAME"

LAST_BLOCK_FILE="$LAST_BLOCK_FILE"

port_blocked=false
block_start=0
HIGH_LATENCY_COUNT=0

# ============================================
# 修复点 1：判断当前端口是否已被防火墙阻断
# ============================================
is_port_blocked() {
    iptables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null || \
    ip6tables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null
}

clean_rules() {
    iptables -D INPUT -p tcp --dport $LOCAL_PORT -j DROP 2>/dev/null || true
    ip6tables -D INPUT -p tcp --dport $LOCAL_PORT -j DROP 2>/dev/null || true

    # 防止历史叠加，最多清 10 次
    for i in {1..10}; do
        iptables -D INPUT -p tcp --dport $LOCAL_PORT -j DROP 2>/dev/null || break
    done
    for i in {1..10}; do
        ip6tables -D INPUT -p tcp --dport $LOCAL_PORT -j DROP 2>/dev/null || break
    done
}

send_tg_block() {
    [ "\$TG_ENABLE" != "1" ] && return
    local time_now
    time_now=\$(date '+%F %T')
    curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TG_CHAT_ID}" \
        -d text="💻 名称：\$SERVER_NAME
⚠️ 状态：\$LOCAL_PORT 端口已阻断
⏰ 时间：\$time_now" >/dev/null
}

send_tg_unblock() {
    [ "\$TG_ENABLE" != "1" ] && return
    local time_now
    time_now=\$(date '+%F %T')
    curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TG_CHAT_ID}" \
        -d text="💻 名称：\$SERVER_NAME
✅ 状态：\$LOCAL_PORT 端口已恢复
⏰ 时间：\$time_now" >/dev/null
}

# ============================================
# 修复点 2：脚本启动时同步真实防火墙状态
# ============================================
if is_port_blocked; then
    port_blocked=true
    block_start=\$(date +%s)
fi

block_port() {
    # 修复点 3：防止重复添加 DROP 规则
    is_port_blocked && return

    clean_rules
    iptables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
    ip6tables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
    date '+%F %T' > "\$LAST_BLOCK_FILE"
    send_tg_block
    port_blocked=true
    block_start=\$(date +%s)
}

unblock_port() {
    clean_rules
    send_tg_unblock
    port_blocked=false
    HIGH_LATENCY_COUNT=0
}

while true; do
    ping_output=\$(ping -6 -c 1 -W 1 \$TARGET_IP 2>/dev/null)
    latency=\$(echo "\$ping_output" | grep "time=" | sed -E 's/.*time=([0-9.]+).*/\1/')

    if ! \$port_blocked; then
        if [ -z "\$latency" ]; then
            HIGH_LATENCY_COUNT=\$((HIGH_LATENCY_COUNT+1))
        else
            latency_int=\${latency%.*}
            [ "\$latency_int" -ge "\$LATENCY_THRESHOLD" ] && \
                HIGH_LATENCY_COUNT=\$((HIGH_LATENCY_COUNT+1)) || \
                HIGH_LATENCY_COUNT=0
        fi

        [ "\$HIGH_LATENCY_COUNT" -ge "\$REQUIRED_CONSECUTIVE" ] && block_port
    else
        now=\$(date +%s)
        elapsed=\$((now - block_start))
        [ "\$elapsed" -ge "\$BLOCK_DURATION" ] && unblock_port
    fi

    sleep 5
done
EOF

    chmod +x "$SCRIPT_PATH"

cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=Ping Monitor - Auto Close Port $PORT (IPv4 + IPv6)
After=network-online.target

[Service]
ExecStart=$SCRIPT_PATH
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
    echo "✅ 安装完成，服务已启动"
}

# ============================================
# 清理并复原
# ============================================
remove_monitor() {
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE_NAME"
    systemctl daemon-reload

    rm -f "$SCRIPT_PATH"
    rm -f "$LAST_BLOCK_FILE"

    for t in iptables ip6tables; do
        while true; do
            n=$($t -L INPUT --line-numbers -n | grep "tcp dpt:$DEFAULT_PORT" | awk '{print $1}' | head -n1)
            [ -z "$n" ] && break
            $t -D INPUT "$n"
        done
    done

    echo "✅ 已完全复原"
}

# ============================================
# 菜单
# ============================================
show_menu() {
    echo "============================="
    echo " Ping Monitor 管理脚本 v1.1"
    echo "============================="
    echo " 脚本状态：$(get_service_status) 丨TG 通知 ：$(get_tg_status)"
    echo " 监控端口：$(get_monitor_port)  丨最近阻断：$(get_last_block_time)"
    echo "-----------------------------"
    echo "1) 安装并启动监控"
    echo "2) 清理并复原"
    echo "3) TG通知设置"
    echo "0) 退出"
    echo "============================="
    read -rp "请选择: " c

    case "$c" in
        1) install_monitor ;;
        2) remove_monitor ;;
        3) tg_settings ;;
        0) exit 0 ;;
    esac
}

# ============================================
# 脚本入口
# ============================================
show_menu