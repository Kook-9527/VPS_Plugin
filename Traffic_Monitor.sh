#!/bin/bash
# ============================================
# 智能流量密度监控 & 端口阻断脚本 (滑动窗口版)
# 核心逻辑：
#   1. 维护一个长度为 [WINDOW_DURATION] 秒的时间窗口。
#   2. 每秒检测一次全网卡流量差值 (已排除业务端口流量)。
#   3. 如果过去30秒内，有10次以上差值超过2Mbps，则判定为攻击。
#   4. 触发阻断指定端口 (如 55555)。
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_BLOCK_PORT=55555           # 要阻断的目标端口
DIFF_THRESHOLD=2                   # 流量差值阈值 (Mbps)
BLOCK_DURATION=300                 # 阻断时间 (秒)
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
    NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null || echo "eth0")
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
# 生成核心监控脚本
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

# --- 业务流量隔离统计核心修正 ---
setup_stats() {
    # IPv4规则清理
    iptables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    iptables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    iptables -F TRAFFIC_IN 2>/dev/null || true
    iptables -F TRAFFIC_OUT 2>/dev/null || true
    iptables -X TRAFFIC_IN 2>/dev/null || true
    iptables -X TRAFFIC_OUT 2>/dev/null || true

    # IPv6规则清理
    ip6tables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    ip6tables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    ip6tables -F TRAFFIC_IN 2>/dev/null || true
    ip6tables -F TRAFFIC_OUT 2>/dev/null || true
    ip6tables -X TRAFFIC_IN 2>/dev/null || true
    ip6tables -X TRAFFIC_OUT 2>/dev/null || true

    # 创建IPv4统计链
    iptables -N TRAFFIC_IN
    iptables -N TRAFFIC_OUT
    iptables -A TRAFFIC_IN -p tcp --dport \$TARGET_PORT
    iptables -A TRAFFIC_IN -p udp --dport \$TARGET_PORT
    iptables -A TRAFFIC_OUT -p tcp --sport \$TARGET_PORT
    iptables -A TRAFFIC_OUT -p udp --sport \$TARGET_PORT
    iptables -I INPUT 1 -j TRAFFIC_IN
    iptables -I OUTPUT 1 -j TRAFFIC_OUT

    # 创建IPv6统计链（新增）
    ip6tables -N TRAFFIC_IN
    ip6tables -N TRAFFIC_OUT
    ip6tables -A TRAFFIC_IN -p tcp --dport \$TARGET_PORT
    ip6tables -A TRAFFIC_IN -p udp --dport \$TARGET_PORT
    ip6tables -A TRAFFIC_OUT -p tcp --sport \$TARGET_PORT
    ip6tables -A TRAFFIC_OUT -p udp --sport \$TARGET_PORT
    ip6tables -I INPUT 1 -j TRAFFIC_IN
    ip6tables -I OUTPUT 1 -j TRAFFIC_OUT
}



send_tg() {
    [ "\$TG_ENABLE" != "已开启" ] && return
    local status_msg="\$1"
    local time_now=\$(date '+%Y-%m-%d %H:%M:%S')
    local text="🛡️ **流量防御系统**%0A服务器：\$SERVER_NAME%0A消息：\$status_msg%0A时间：\$time_now"
    curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" -d "chat_id=\$TG_CHATID" -d "text=\$text" > /dev/null
}

clean_rules() {
    # 清理IPv4阻断规则
    while true; do
        num=\$(iptables -L INPUT --line-numbers -n | grep "DROP" | grep "dpt:\$TARGET_PORT" | awk '{print \$1}' | head -n1)
        [ -z "\$num" ] && break
        iptables -D INPUT \$num
    done
    
    # 清理IPv6阻断规则
    while true; do
        num=\$(ip6tables -L INPUT --line-numbers -n | grep "DROP" | grep "dpt:\$TARGET_PORT" | awk '{print \$1}' | head -n1)
        [ -z "\$num" ] && break
        ip6tables -D INPUT \$num
    done
}


get_pure_bytes() {
    # 获取网卡总流量
    local total=\$(awk -v iface="\$INTERFACE" '\$1 ~ iface":" {print \$2, \$10}' /proc/net/dev | sed 's/:/ /g')
    
    # 获取IPv4业务端口统计
    local p4_in=\$(iptables -L TRAFFIC_IN -n -v -x | grep "dpt:\$TARGET_PORT" | awk '{sum+=\$2} END {print sum+0}')
    local p4_out=\$(iptables -L TRAFFIC_OUT -n -v -x | grep "sport:\$TARGET_PORT" | awk '{sum+=\$2} END {print sum+0}')
    
    # 获取IPv6业务端口统计（新增）
    local p6_in=\$(ip6tables -L TRAFFIC_IN -n -v -x | grep "dpt:\$TARGET_PORT" | awk '{sum+=\$2} END {print sum+0}')
    local p6_out=\$(ip6tables -L TRAFFIC_OUT -n -v -x | grep "sport:\$TARGET_PORT" | awk '{sum+=\$2} END {print sum+0}')
    
    read t_in t_out <<< "\$total"
    
    # 核心：扣除IPv4和IPv6的业务流量
    local pure_in=\$((t_in - p4_in - p6_in))
    local pure_out=\$((t_out - p4_out - p6_out))
    
    # 防止出现负数
    [ \$pure_in -lt 0 ] && pure_in=0
    [ \$pure_out -lt 0 ] && pure_out=0
    
    echo "\$pure_in \$pure_out"
}


setup_stats
port_blocked=false
block_start_time=0
history_window=()

while true; do
    read rx1 tx1 <<< \$(get_pure_bytes)
    sleep 1
    read rx2 tx2 <<< \$(get_pure_bytes)

    stats=\$(awk -v r1=\$rx1 -v r2=\$rx2 -v t1=\$tx1 -v t2=\$tx2 'BEGIN {
        rx_speed = (r2 - r1) * 8 / 1024 / 1024;
        tx_speed = (t2 - t1) * 8 / 1024 / 1024;
        diff = rx_speed - tx_speed;
        if (diff < 0) diff = 0;
        printf "%.2f %.2f %.2f", rx_speed, tx_speed, diff
    }')
    read rx_mbps tx_mbps diff_mbps <<< "\$stats"
    is_bad=\$(awk -v diff="\$diff_mbps" -v thresh="\$DIFF_THRESHOLD" 'BEGIN {print (diff > thresh) ? 1 : 0}')

    history_window+=(\$is_bad)
    [ \${#history_window[@]} -gt \$WINDOW_DURATION ] && history_window=("\${history_window[@]:1}")
    total_bad=0
    for val in "\${history_window[@]}"; do total_bad=\$((total_bad + val)); done

    if ! \$port_blocked; then
        echo "\$(date '+%H:%M:%S') [监控] 背景下载:\${rx_mbps}M | 差值:\${diff_mbps}M | 密度:\${total_bad}/\${WINDOW_DURATION}"
        if [ "\$total_bad" -ge "\$TRIGGER_COUNT" ]; then
            # 阻断端口
            iptables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
            iptables -A INPUT -p udp --dport \$TARGET_PORT -j DROP
            ip6tables -A INPUT -p tcp --dport \$TARGET_PORT -j DROP
            ip6tables -A INPUT -p udp --dport \$TARGET_PORT -j DROP
            
            send_tg "⚠️ 检测到持续攻击，已阻断端口 \$TARGET_PORT"
            port_blocked=true
            block_start_time=\$(date +%s)
        fi
    else
        now=\$(date +%s)
        elapsed=\$((now - block_start_time))
        remaining=\$((BLOCK_DURATION - elapsed))
        if [ "\$is_bad" -eq 1 ]; then
            block_start_time=\$now
            echo "\$(date '+%H:%M:%S') [⚡ 续期] 背景异常持续中"
        else
            echo "\$(date '+%H:%M:%S') [🛡️ 防御] 剩余:\${remaining}s | 背景差值:\${diff_mbps}M"
        fi
        if [ "\$remaining" -le 0 ]; then
            clean_rules
            send_tg "✅ 攻击停止，端口 \$TARGET_PORT 已自动解封"
            port_blocked=false
            history_window=()
        fi
    fi
done
EOF
    chmod +x "$SCRIPT_PATH"
}

# =========================
# 菜单与配置函数
# =========================
setup_tg() {
    echo "--- TG 通知配置 ---"
    read -rp "是否开启 TG 通知? [Y/n]: " choice; choice=${choice:-y}
    if [[ "$choice" == [yY] ]]; then
        read -rp "请输入此服务器备注名称: " SERVER_NAME
        read -rp "请输入TG机器人Token: " TG_TOKEN
        read -rp "请输入TG账号ID: " TG_CHATID
        TG_ENABLE="已开启"
    else
        TG_ENABLE="已关闭"
    fi
    save_config
    [ -f /etc/systemd/system/$SERVICE_NAME ] && systemctl restart "$SERVICE_NAME" || true
    echo "✅ TG 配置已更新"
}

modify_params() {
    echo "============================="
    echo "       修改运行参数"
    echo "============================="
    read -rp "1. 目标阻断端口 [当前: $BLOCK_PORT]: " input; BLOCK_PORT=${input:-$BLOCK_PORT}
    read -rp "2. 流量差值阈值 Mbps [当前: $DIFF_THRESHOLD]: " input; DIFF_THRESHOLD=${input:-$DIFF_THRESHOLD}
    read -rp "3. 检测时间窗口：秒 [当前: $WINDOW_DURATION]: " input; WINDOW_DURATION=${input:-$WINDOW_DURATION}
    read -rp "4. 窗口内触发次数 [当前: $TRIGGER_COUNT]: " input; TRIGGER_COUNT=${input:-$TRIGGER_COUNT}
    read -rp "5. 阻断持续时间：秒 [当前: $BLOCK_DURATION]: " input; BLOCK_DURATION=${input:-$BLOCK_DURATION}
    read -rp "6. 监控网卡接口 [当前: $NET_INTERFACE]: " input; NET_INTERFACE=${input:-$NET_INTERFACE}
    save_config; create_monitor_script
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    echo "✅ 参数已保存并应用。"
}

install_monitor() {
    echo "📥 安装中..."
    install_dependencies
    read -rp "请输入受到攻击时要阻断的端口 [默认 $BLOCK_PORT]: " USER_PORT
    BLOCK_PORT="${USER_PORT:-$BLOCK_PORT}"
    setup_tg
    create_monitor_script
    cat << EOF > "/etc/systemd/system/$SERVICE_NAME"
[Unit]
Description=Traffic Monitor (Sliding Window)
After=network.target
[Service]
ExecStart=$SCRIPT_PATH
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now "$SERVICE_NAME"
    echo "✅ 监控已启动。"
}

remove_monitor() {
    echo "🛑 正在卸载..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    iptables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    iptables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    iptables -F TRAFFIC_IN 2>/dev/null || true; iptables -X TRAFFIC_IN 2>/dev/null || true
    iptables -F TRAFFIC_OUT 2>/dev/null || true; iptables -X TRAFFIC_OUT 2>/dev/null || true
    for proto in iptables ip6tables; do
        while true; do
            num=$($proto -L INPUT --line-numbers -n | grep "DROP" | grep "dpt:$BLOCK_PORT" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            $proto -D INPUT $num
        done
    done
    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH" "$CONFIG_FILE"
    echo "✅ 清理完成。"
}

# ============================================
# 主界面
# ============================================
while true; do
    status_run=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "已运行" || echo "未运行")
    clear
    echo "============================="
    echo " 智能流量密度监控 v1.0.2"
    echo " by：kook9527"
    echo "============================="
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控网卡：$NET_INTERFACE丨阻断端口：$BLOCK_PORT"
    echo "当前阈值：差值 > ${DIFF_THRESHOLD}Mbps丨业务隔离：已完全排除端口 $BLOCK_PORT 的流量"
    echo "阻断逻辑：${WINDOW_DURATION}秒窗口内出现 > ${TRIGGER_COUNT}次异常"
    echo "延时逻辑：阻断期内若检测到异常，自动重置${BLOCK_DURATION}秒"
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
