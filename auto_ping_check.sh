#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
# ============================================
# Ping Monitor 管理脚本
# 功能：
# 1. 持续 ping IPv6 或 IPv4 目标地址
# 2. 延迟异常或中断时封禁端口（IPv4 + IPv6）
# 3. 网络恢复后自动解除阻断
# 4. TG通知可选，支持服务器备注
# 5. 菜单管理，显示状态、端口、最近阻断
# 6. systemd 常驻运行，稳定可靠
# ============================================

# --------------------------
# 全局参数
# --------------------------
DEFAULT_PORT=55555                       # 默认端口
TARGET_IP="2606:4700:4700::1111"         # 目标IP
LATENCY_THRESHOLD=10                     # 延迟阈值(ms)
BLOCK_DURATION=120                       # 阻断持续时间(秒)
REQUIRED_CONSECUTIVE=3                   # 连续异常次数触发阻断

SERVICE_NAME="ping-monitor.service"      # systemd 服务名
SCRIPT_PATH="/root/check_ping_loop.sh"   # 监控脚本路径
LAST_BLOCK_FILE="/root/ping_monitor_last_block.txt"  # 最近阻断记录文件

# ============================================
# 状态读取函数
# ============================================
get_service_status() {
    # 检查 systemd 服务状态
    systemctl is-active --quiet "$SERVICE_NAME" && echo "运行中" || echo "关闭"
}

get_tg_status() {
    # 检查 TG 是否启用
    [ -f "$SCRIPT_PATH" ] && grep -q "^TG_ENABLE=1" "$SCRIPT_PATH" && echo "运行中" || echo "关闭"
}

get_monitor_port() {
    # 读取当前监控端口
    [ -f "$SCRIPT_PATH" ] && grep "^LOCAL_PORT=" "$SCRIPT_PATH" | cut -d= -f2 || echo "-"
}

get_last_block_time() {
    # 读取最近阻断时间
    [ -f "$LAST_BLOCK_FILE" ] && cat "$LAST_BLOCK_FILE" || echo "无"
}

# ============================================
# TG设置函数
# ============================================
tg_settings() {
    [ ! -f "$SCRIPT_PATH" ] && echo "❌ 服务未安装" && return

    TG_ENABLE=$(grep "^TG_ENABLE=" "$SCRIPT_PATH" | cut -d= -f2)
    if [ "$TG_ENABLE" != "1" ]; then
        # 未启用 TG
        read -rp "是否启用 Telegram 通知？[Y/n]: " c
        if [[ -z "$c" || "$c" =~ ^[Yy]$ ]]; then
            read -rp "请输入TG机器人Token: " token
            read -rp "请输入TG账号ID: " chat
            read -rp "请输入本服务器备注（如：小鸡1）: " SERVER_NAME
            SERVER_NAME="${SERVER_NAME:-未命名服务器}"
            sed -i "s/^TG_ENABLE=.*/TG_ENABLE=1/" "$SCRIPT_PATH"
            sed -i "s|^TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"$token\"|" "$SCRIPT_PATH"
            sed -i "s|^TG_CHAT_ID=.*|TG_CHAT_ID=\"$chat\"|" "$SCRIPT_PATH"
            sed -i "s|^SERVER_NAME=.*|SERVER_NAME=\"$SERVER_NAME\"|" "$SCRIPT_PATH"
        fi
    else
        # 已启用 TG，可修改或关闭
        echo "1) 修改 TG 配置"
        echo "2) 关闭 TG 通知"
        echo "0) 返回"
        read -rp "请选择: " sub
        case "$sub" in
            1)
                read -rp "新的TG机器人Token: " token
                read -rp "新的TG账号ID: " chat
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
# 安装监控脚本及 systemd 服务
# ============================================
install_monitor() {
    # 端口选择
    read -rp "请输入监控端口 [默认 $DEFAULT_PORT]: " p
    PORT="${p:-$DEFAULT_PORT}"

    # TG通知选项
    read -rp "是否启用 Telegram 通知？[Y/n]: " c
    if [[ -z "$c" || "$c" =~ ^[Yy]$ ]]; then
        TG_ENABLE=1
        read -rp "TG机器人Token: " TG_BOT_TOKEN
        read -rp "TG账号ID: " TG_CHAT_ID
        read -rp "请输入本服务器备注（如：小鸡1）: " SERVER_NAME
        SERVER_NAME="${SERVER_NAME:-未命名服务器}"
    else
        TG_ENABLE=0
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
        SERVER_NAME="未命名服务器"
    fi

    # ----------------------------
    # 生成实际监控脚本
    # ----------------------------
cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

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
block_start_time=0
HIGH_LATENCY_COUNT=0

# ----------------------------
# 检查端口是否已阻断
# ----------------------------
is_port_blocked() {
    iptables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null || \
    ip6tables -C INPUT -p tcp --dport \$LOCAL_PORT -j DROP &>/dev/null
}

# ----------------------------
# 清理防火墙规则
# ----------------------------
clean_rules() {
    for proto in iptables ip6tables; do
        while true; do
            num=\$($proto -L INPUT --line-numbers -n | grep "tcp dpt:\$LOCAL_PORT" | awk '{print \$1}' | head -n1)
            [ -z "\$num" ] && break
            \$proto -D INPUT \$num
        done
    done
}

# ----------------------------
# 发送 TG 阻断消息
# ----------------------------
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

# ----------------------------
# 发送 TG 恢复消息
# ----------------------------
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

# ----------------------------
# 启动时同步防火墙状态
# ----------------------------
if is_port_blocked; then
    port_blocked=true
    block_start_time=\$(date +%s)
fi

# ----------------------------
# 阻断端口函数
# ----------------------------
block_port() {
    clean_rules
    iptables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP
    ip6tables -A INPUT -p tcp --dport \$LOCAL_PORT -j DROP

    echo "\$(date '+%F %T')" > "\$LAST_BLOCK_FILE"

    send_tg_block   # 【TG消息】

    echo "\$(date '+%F %T') ⚠️ 连续 \$REQUIRED_CONSECUTIVE 次异常，已关闭端口 \$LOCAL_PORT"

    port_blocked=true
    block_start_time=\$(date +%s)
}

# ----------------------------
# 解除端口阻断函数
# ----------------------------
unblock_port() {
    clean_rules
    send_tg_unblock   # 【TG消息】
    echo "\$(date '+%F %T') ✅ 阻断时间结束，端口已恢复 \$LOCAL_PORT"
    port_blocked=false
    block_start_time=0
    HIGH_LATENCY_COUNT=0
}

# ----------------------------
# 主循环：ping检测、阻断/恢复
# ----------------------------
while true; do
    ping_output=\$(ping -6 -c 1 -W 1 \$TARGET_IP 2>/dev/null)
    latency=\$(echo "\$ping_output" | grep "time=" | sed -E 's/.*time=([0-9.]+).*/\1/')
    latency_int=0
    [ -n "\$latency" ] && latency_int=\${latency%.*}

    if [ "\$port_blocked" = false ]; then
        # 未阻断状态，统计连续异常
        if [ -z "\$latency" ] || [ "\$latency_int" -ge "\$LATENCY_THRESHOLD" ]; then
            HIGH_LATENCY_COUNT=\$((HIGH_LATENCY_COUNT+1))
        else
            HIGH_LATENCY_COUNT=0
        fi

        if [ "\$HIGH_LATENCY_COUNT" -ge "\$REQUIRED_CONSECUTIVE" ]; then
            block_port
        fi
    else
        # 已阻断状态，等待恢复或 BLOCK_DURATION 到
        if [ -n "\$latency" ] && [ "\$latency_int" -lt "\$LATENCY_THRESHOLD" ]; then
            unblock_port
        else
            now=\$(date +%s)
            elapsed=\$((now - block_start_time))
            if [ "\$elapsed" -ge "\$BLOCK_DURATION" ]; then
                unblock_port
            fi
        fi
    fi

    sleep 5
done
EOF

    chmod +x "$SCRIPT_PATH"   # 【修改点1】脚本可执行

    # ----------------------------
    # systemd 服务文件
    # ----------------------------
cat <<EOF >/etc/systemd/system/$SERVICE_NAME
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

    # 重新加载 systemd 并启动服务
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"

    echo "✅ 安装完成：服务已启动"
    echo "✅ 状态命令行：systemctl status $SERVICE_NAME"
    echo "✅ 日志命令行：journalctl -u $SERVICE_NAME -f"
}

# ============================================
# 清理与复原函数
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
# 菜单函数
# ============================================
show_menu() {
    echo "============================="
    echo " Ping Monitor 管理脚本 v1.1"
    echo "============================="
    echo " 脚本状态：$(get_service_status) 丨TG 通知：$(get_tg_status)"
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

# 启动菜单
show_menu