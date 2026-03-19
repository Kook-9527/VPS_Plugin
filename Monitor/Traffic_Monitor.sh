#!/bin/bash
# ============================================
# DDoS流量监控脚本
# 核心逻辑：
#   1. 自动检测并排除 xray/sing-box 监听的所有端口
#   2. 维护一个长度为 [WINDOW_DURATION] 秒的时间窗口
#   3. 每秒检测一次全网卡流量差值（已自动排除代理端口流量）
#   4. 如果过去30秒内，有10次以上异常流量，则判定为攻击
#   5. 触发阻断指定端口（如 55555）
#   6. 阻断期间如检测到攻击，自动延长阻断时间
#   7. 攻击停止30秒后自动解封
# 
# 特性：
#   - 完全自动化：无需手动配置排除端口
#   - 智能检测：自动发现所有代理端口
#   - 多端口支持：阻断端口支持逗号分隔（如：55555,55556）
#   - TG通知：阻断/解封实时推送
# ============================================

set -e

# =========================
# 默认参数
# =========================
DEFAULT_BLOCK_PORT=55555           # 要阻断的目标端口
RATIO_THRESHOLD=30                 # 上传/下载比率阈值 (%) - 比率越低越可能是DDoS
DL_THRESHOLD=2                     # 下载流量阈值 (Mbps)
BLOCK_DURATION=300                 # 阻断时间 (秒)
WINDOW_DURATION=30                 # 检测时间窗口 (秒)
TRIGGER_COUNT=10                   # 窗口内触发次数阈值
NET_INTERFACE=""                   # 网卡名称 (留空自动检测)

SERVICE_NAME="traffic-monitor.service"
SCRIPT_PATH="/root/traffic_Log.sh"
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
RATIO_THRESHOLD=${RATIO_THRESHOLD:-$RATIO_THRESHOLD}
DL_THRESHOLD=${DL_THRESHOLD:-$DL_THRESHOLD}
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
RATIO_THRESHOLD="$RATIO_THRESHOLD"
DL_THRESHOLD="$DL_THRESHOLD"
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
    cat << 'SCRIPT_EOF' > "$SCRIPT_PATH"
#!/bin/bash
export LANG=C
export LC_ALL=C

CONFIG_FILE="/etc/traffic_monitor_config.sh"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

TARGET_PORT=$BLOCK_PORT
INTERFACE="$NET_INTERFACE"

setup_stats() {
    # 自动检测xray和sing-box监听的端口
    local proxy_ports=""
    
    # 检测xray监听的端口
    if pgrep -x "xray" > /dev/null; then
        local xray_ports=$(ss -tunlp | grep "xray" | awk '{print $5}' | grep -oP ':\K[0-9]+' | sort -u | tr '\n' ',')
        proxy_ports="${proxy_ports}${xray_ports}"
    fi
    
    # 检测sing-box监听的端口
    if pgrep -x "sing-box" > /dev/null; then
        local singbox_ports=$(ss -tunlp | grep "sing-box" | awk '{print $5}' | grep -oP ':\K[0-9]+' | sort -u | tr '\n' ',')
        proxy_ports="${proxy_ports}${singbox_ports}"
    fi
    
    # 去除末尾的逗号并去重
    proxy_ports=$(echo "$proxy_ports" | sed 's/,$//')
    local all_exclude_ports=$(echo "$proxy_ports" | tr ',' '\n' | sort -u | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
    
    # 输出日志
    if [ -n "$all_exclude_ports" ]; then
        echo "$(date '+%H:%M:%S') [初始化] 自动检测到代理端口：$all_exclude_ports"
        echo "$(date '+%H:%M:%S') [初始化] 这些端口的流量将被完全排除，不计入DDoS检测"
    else
        echo "$(date '+%H:%M:%S') [初始化] 未检测到xray/sing-box进程"
    fi
    
    # IPv4清理
    iptables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    iptables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    iptables -F TRAFFIC_IN 2>/dev/null || true
    iptables -F TRAFFIC_OUT 2>/dev/null || true
    iptables -X TRAFFIC_IN 2>/dev/null || true
    iptables -X TRAFFIC_OUT 2>/dev/null || true

    # IPv6清理
    ip6tables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    ip6tables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    ip6tables -F TRAFFIC_IN 2>/dev/null || true
    ip6tables -F TRAFFIC_OUT 2>/dev/null || true
    ip6tables -X TRAFFIC_IN 2>/dev/null || true
    ip6tables -X TRAFFIC_OUT 2>/dev/null || true

    # 创建IPv4统计链
    iptables -N TRAFFIC_IN
    iptables -N TRAFFIC_OUT
    
    # 只排除自动检测到的代理端口
    if [ -n "$all_exclude_ports" ]; then
        IFS=',' read -ra PORTS <<< "$all_exclude_ports"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            [ -z "$port" ] && continue
            iptables -A TRAFFIC_IN -p tcp --dport $port
            iptables -A TRAFFIC_IN -p udp --dport $port
            iptables -A TRAFFIC_OUT -p tcp --sport $port
            iptables -A TRAFFIC_OUT -p udp --sport $port
        done
    fi
    
    iptables -I INPUT 1 -j TRAFFIC_IN
    iptables -I OUTPUT 1 -j TRAFFIC_OUT

    # 创建IPv6统计链
    ip6tables -N TRAFFIC_IN
    ip6tables -N TRAFFIC_OUT
    
    if [ -n "$all_exclude_ports" ]; then
        IFS=',' read -ra PORTS <<< "$all_exclude_ports"
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            [ -z "$port" ] && continue
            ip6tables -A TRAFFIC_IN -p tcp --dport $port
            ip6tables -A TRAFFIC_IN -p udp --dport $port
            ip6tables -A TRAFFIC_OUT -p tcp --sport $port
            ip6tables -A TRAFFIC_OUT -p udp --sport $port
        done
    fi
    
    ip6tables -I INPUT 1 -j TRAFFIC_IN
    ip6tables -I OUTPUT 1 -j TRAFFIC_OUT
    
    # 保存实际排除的端口列表到全局变量
    ACTUAL_EXCLUDE_PORTS="$all_exclude_ports"
}

send_tg() {
    [ "$TG_ENABLE" != "已开启" ] && return
    local status_msg="$1"
    local time_now=$(date '+%Y-%m-%d %H:%M:%S')
    local text="🛡️ DDoS流量监控%0A━━━━━━━━━━━━━━━%0A服务器: $SERVER_NAME%0A消息: $status_msg%0A时间: $time_now"
    
    echo "$(date '+%H:%M:%S') [TG] 准备发送: $status_msg"
    
    # 增加到5次重试，使用指数退避
    local retry=0
    local max_retry=5
    local wait_time=3
    
    while [ $retry -lt $max_retry ]; do
        local result=$(curl -s -m 20 --connect-timeout 10 -X POST \
            "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
            -d "chat_id=$TG_CHATID" \
            -d "text=$text" 2>&1)
        
        if echo "$result" | grep -q '"ok":true'; then
            echo "$(date '+%H:%M:%S') [TG] ✅ 发送成功"
            return 0
        fi
        
        retry=$((retry + 1))
        
        # 记录详细错误（但不输出完整result，太长）
        if echo "$result" | grep -q "timed out"; then
            echo "$(date '+%H:%M:%S') [TG] ❌ 第${retry}次失败: 连接超时"
        elif echo "$result" | grep -q "Connection refused"; then
            echo "$(date '+%H:%M:%S') [TG] ❌ 第${retry}次失败: 连接被拒绝"
        else
            echo "$(date '+%H:%M:%S') [TG] ❌ 第${retry}次失败: 未知错误"
        fi
        
        # 指数退避：3秒 -> 6秒 -> 12秒 -> 24秒
        if [ $retry -lt $max_retry ]; then
            echo "$(date '+%H:%M:%S') [TG] 等待 ${wait_time}秒 后重试..."
            sleep $wait_time
            wait_time=$((wait_time * 2))
            [ $wait_time -gt 30 ] && wait_time=30  # 最多等30秒
        fi
    done
    
    echo "$(date '+%H:%M:%S') [TG] ⚠️ 最终失败，已重试${max_retry}次"
    return 1
}


clean_rules() {
    # 分割端口列表
    IFS=',' read -ra PORTS <<< "$TARGET_PORT"
    
    # 清理每个端口的IPv4规则
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        while true; do
            num=$(iptables -L INPUT --line-numbers -n 2>/dev/null | grep "DROP" | grep "dpt:$port" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            iptables -D INPUT $num 2>/dev/null || break
        done
    done
    
    # 清理每个端口的IPv6规则
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        while true; do
            num=$(ip6tables -L INPUT --line-numbers -n 2>/dev/null | grep "DROP" | grep "dpt:$port" | awk '{print $1}' | head -n1)
            [ -z "$num" ] && break
            ip6tables -D INPUT $num 2>/dev/null || break
        done
    done
    
    echo "$(date '+%H:%M:%S') [清理] 已移除所有阻断规则"
}

get_pure_bytes() {
    local total=$(awk -v iface="$INTERFACE" '$1 ~ iface":" {print $2, $10}' /proc/net/dev | sed 's/:/ /g')
    
    # 使用实际排除的端口列表（包括自动检测的）
    IFS=',' read -ra PORTS <<< "$ACTUAL_EXCLUDE_PORTS"
    
    local p4_in=0
    local p4_out=0
    local p6_in=0
    local p6_out=0
    
    # 循环统计每个端口的流量
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        p4_in=$((p4_in + $(iptables -L TRAFFIC_IN -n -v -x 2>/dev/null | grep -w "dpt:$port" | awk '{sum+=$2} END {print sum+0}')))
        p4_out=$((p4_out + $(iptables -L TRAFFIC_OUT -n -v -x 2>/dev/null | grep -w "sport:$port" | awk '{sum+=$2} END {print sum+0}')))
        p6_in=$((p6_in + $(ip6tables -L TRAFFIC_IN -n -v -x 2>/dev/null | grep -w "dpt:$port" | awk '{sum+=$2} END {print sum+0}')))
        p6_out=$((p6_out + $(ip6tables -L TRAFFIC_OUT -n -v -x 2>/dev/null | grep -w "sport:$port" | awk '{sum+=$2} END {print sum+0}')))
    done
    
    read t_in t_out <<< "$total"
    
    local pure_in=$((t_in - p4_in - p6_in))
    local pure_out=$((t_out - p4_out - p6_out))
    
    [ $pure_in -lt 0 ] && pure_in=0
    [ $pure_out -lt 0 ] && pure_out=0
    
    echo "$pure_in $pure_out"
}

setup_stats
ACTUAL_EXCLUDE_PORTS=""
port_blocked=false
block_start_time=0
block_end_time=0
last_attack_time=0
history_window=()
loop_count=0

while true; do
    loop_count=$((loop_count + 1))
    
    # 心跳检查
    if [ $((loop_count % 60)) -eq 0 ]; then
        echo "$(date '+%H:%M:%S') [心跳] 服务运行正常 | 阻断状态:$port_blocked"
    fi
    
    read rx1 tx1 <<< $(get_pure_bytes)
    sleep 1
    read rx2 tx2 <<< $(get_pure_bytes)

    stats=$(awk -v r1=$rx1 -v r2=$rx2 -v t1=$tx1 -v t2=$tx2 'BEGIN {
        rx_speed = (r2 - r1) * 8 / 1024 / 1024;
        tx_speed = (t2 - t1) * 8 / 1024 / 1024;
        diff = rx_speed - tx_speed;
        if (diff < 0) diff = 0;
        
        # 计算上传/下载比率
        if (rx_speed >= 0.01) {  # 只要有很小的下载流量就计算比率
            ratio = (tx_speed / rx_speed) * 100;
        } else {
            ratio = 100;  # 只有在几乎没有下载时才设为100%
        }
        
        printf "%.2f %.2f %.2f %.2f", rx_speed, tx_speed, diff, ratio
    }')
    read rx_mbps tx_mbps diff_mbps ratio <<< "$stats"
    
    # 智能判断：基于比率 + 下载阈值
    is_bad=$(awk -v ratio="$ratio" -v rx="$rx_mbps" -v ratio_threshold="$RATIO_THRESHOLD" -v dl_threshold="$DL_THRESHOLD" 'BEGIN {
        if (rx > dl_threshold && ratio < ratio_threshold) print 1;
        else print 0;
    }')

    history_window+=($is_bad)
    [ ${#history_window[@]} -gt $WINDOW_DURATION ] && history_window=("${history_window[@]:1}")
    total_bad=0
    for val in "${history_window[@]}"; do total_bad=$((total_bad + val)); done

    if ! $port_blocked; then
        echo "$(date '+%H:%M:%S') [监控] 下载:${rx_mbps}Mbps 上传:${tx_mbps}Mbps | 比率:${ratio}% | 检测:${total_bad}/${WINDOW_DURATION}s内"
        
        if [ "$total_bad" -ge "$TRIGGER_COUNT" ]; then
            echo "$(date '+%H:%M:%S') [告警] 检测到持续攻击，开始阻断端口 $TARGET_PORT"
    
            # 分割端口列表并逐个阻断
            IFS=',' read -ra PORTS <<< "$TARGET_PORT"
            for port in "${PORTS[@]}"; do
                port=$(echo "$port" | tr -d ' ')
                iptables -A INPUT -p tcp --dport $port -j DROP 2>/dev/null
                iptables -A INPUT -p udp --dport $port -j DROP 2>/dev/null
                ip6tables -A INPUT -p tcp --dport $port -j DROP 2>/dev/null
                ip6tables -A INPUT -p udp --dport $port -j DROP 2>/dev/null
            done
    
            send_tg "检测到持续攻击，已阻断端口 $TARGET_PORT"
    
            port_blocked=true
            block_start_time=$(date +%s)
            last_attack_time=$block_start_time
    
            echo "$(date '+%H:%M:%S') [阻断] 端口已封锁，开始倒计时 ${BLOCK_DURATION}s"
        fi
    else
        now=$(date +%s)
    
        # 使用结束时间而不是持续时间
        if [ "$block_end_time" -eq 0 ]; then
            block_end_time=$((block_start_time + BLOCK_DURATION))
        fi
    
        elapsed=$((now - block_start_time))
        remaining=$((block_end_time - now))
        time_since_last=$((now - last_attack_time))
    
        # 新逻辑：如果检测到攻击
        if [ "$is_bad" -eq 1 ]; then
            last_attack_time=$now
            time_since_last=0
        
            # 如果在最后30秒内检测到攻击，延长结束时间
            if [ "$remaining" -le 30 ]; then
                block_end_time=$((block_end_time + 30))
                remaining=$((block_end_time - now))
                echo "$(date '+%H:%M:%S') 最后30秒内检测到攻击，延长30秒 | 比率:${ratio}% | 已阻断:${elapsed}s | 新剩余:${remaining}s"
            else
                echo "$(date '+%H:%M:%S') 检测到异常流量 | 比率:${ratio}% | 已阻断:${elapsed}s | 剩余:${remaining}s"
            fi
        else
            echo "$(date '+%H:%M:%S') [监控] 流量:${rx_mbps}Mbps | 比率:${ratio}% | 阻断剩余:${remaining}s | 距上次攻击:${time_since_last}s"
        fi
    
        # 解封条件：当前时间超过结束时间 且 距上次攻击超过30秒
        if [ "$now" -ge "$block_end_time" ] && [ "$time_since_last" -ge 30 ]; then
            echo "$(date '+%H:%M:%S') [解封] 阻断时间已到且30秒内无攻击，开始清理规则..."
            clean_rules
            send_tg "攻击停止，端口 $TARGET_PORT 已自动解封"
            echo "$(date '+%H:%M:%S') [解封] 恢复正常监控状态"
        
            port_blocked=false
            history_window=()
            block_start_time=0
            block_end_time=0
            last_attack_time=0
        elif [ "$now" -ge "$block_end_time" ] && [ "$time_since_last" -lt 30 ]; then
            echo "$(date '+%H:%M:%S') [等待] 阻断时间已到，但距上次攻击仅${time_since_last}秒，等待30秒无攻击后解封..."
            # 延长到距上次攻击30秒后
            block_end_time=$((last_attack_time + 30))
        fi
    fi
done
SCRIPT_EOF
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
    echo "提示：阻断端口支持多个，用逗号分隔，如：55555,55556"
    echo "注意：流量排除是自动检测的，不需要手动配置"
    read -rp "1. 目标阻断端口 [当前: $BLOCK_PORT]: " input; BLOCK_PORT=${input:-$BLOCK_PORT}
    read -rp "2. 下载流量阈值 Mbps [当前: $DL_THRESHOLD]: " input; DL_THRESHOLD=${input:-$DL_THRESHOLD}
    read -rp "3. 上传/下载比率阈值 % [当前: $RATIO_THRESHOLD]: " input; RATIO_THRESHOLD=${input:-$RATIO_THRESHOLD}
    read -rp "4. 检测时间窗口：秒 [当前: $WINDOW_DURATION]: " input; WINDOW_DURATION=${input:-$WINDOW_DURATION}
    read -rp "5. 窗口内触发次数 [当前: $TRIGGER_COUNT]: " input; TRIGGER_COUNT=${input:-$TRIGGER_COUNT}
    read -rp "6. 阻断持续时间：秒 [当前: $BLOCK_DURATION]: " input; BLOCK_DURATION=${input:-$BLOCK_DURATION}
    read -rp "7. 监控网卡接口 [当前: $NET_INTERFACE]: " input; NET_INTERFACE=${input:-$NET_INTERFACE}
    save_config; create_monitor_script
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    echo "✅ 参数已保存并应用。"
}

install_monitor() {
    echo "📥 安装中..."
    install_dependencies
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "提示：阻断端口支持多个，用逗号分隔"
    echo "说明：流量排除会自动检测 xray/sing-box 端口，无需手动配置"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    sleep 2
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "查看自动检测到的代理端口："
    journalctl -u traffic-monitor.service -n 20 --no-pager | grep "自动检测"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

remove_monitor() {
    echo "🛑 正在卸载..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    iptables -D INPUT -j TRAFFIC_IN 2>/dev/null || true
    iptables -D OUTPUT -j TRAFFIC_OUT 2>/dev/null || true
    iptables -F TRAFFIC_IN 2>/dev/null || true; iptables -X TRAFFIC_IN 2>/dev/null || true
    iptables -F TRAFFIC_OUT 2>/dev/null || true; iptables -X TRAFFIC_OUT 2>/dev/null || true
    
    # 清理多个端口的阻断规则
    IFS=',' read -ra PORTS <<< "$BLOCK_PORT"
    for proto in iptables ip6tables; do
        for port in "${PORTS[@]}"; do
            port=$(echo "$port" | tr -d ' ')
            while true; do
                num=$($proto -L INPUT --line-numbers -n | grep "DROP" | grep "dpt:$port" | awk '{print $1}' | head -n1)
                [ -z "$num" ] && break
                $proto -D INPUT $num
            done
        done
    done
    
    rm -f "/etc/systemd/system/$SERVICE_NAME" "$SCRIPT_PATH" "$CONFIG_FILE"
    echo "✅ 清理完成。"
}

view_logs() {
    while true; do
        clear
        echo "========================================"
        echo "       日志查看选项"
        echo "========================================"
        echo "1) 实时监控日志（滚动显示）"
        echo "2) 查看最近100条日志"
        echo "3) 查看最近的阻断/解封记录"
        echo "4) 查看最近的TG通知记录"
        echo "5) 查看最近30分钟的日志"
        echo "0) 返回主菜单"
        echo "========================================"
        read -rp "请选择 [0-5]: " log_choice
        
        case "$log_choice" in
            1)
                clear
                echo "【实时日志】按 Ctrl+C 退出"
                echo "========================================"
                journalctl -u traffic-monitor.service -f
                ;;
            2)
                clear
                echo "【最近100条日志】"
                echo "========================================"
                journalctl -u traffic-monitor.service -n 100 --no-pager
                read -p "按回车返回..."
                ;;
            3)
                clear
                echo "【阻断/解封记录】"
                echo "========================================"
                journalctl -u traffic-monitor.service --no-pager | grep -E "告警|阻断|解封" | tail -50
                read -p "按回车返回..."
                ;;
            4)
                clear
                echo "【TG通知记录】"
                echo "========================================"
                journalctl -u traffic-monitor.service --no-pager | grep "\[TG\]" | tail -50
                read -p "按回车返回..."
                ;;
            5)
                clear
                echo "【最近30分钟日志】"
                echo "========================================"
                journalctl -u traffic-monitor.service --since "30 min ago" --no-pager
                read -p "按回车返回..."
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项，请重试"
                sleep 1
                ;;
        esac
    done
}


# ============================================
# 主界面
# ============================================
while true; do
    status_run=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "已运行" || echo "未运行")
    clear
    echo "======================================"
    echo " DDoS流量监控+阻断节点端口脚本 v1.0.9"
    echo " by：kook9527"
    echo "======================================"
    echo "脚本状态：$status_run丨TG 通知 ：$TG_ENABLE"
    echo "监控网卡：$NET_INTERFACE  丨阻断端口：$BLOCK_PORT"
    echo "当前阈值：下载 > ${DL_THRESHOLD}Mbps 且 比率 < ${RATIO_THRESHOLD}%"
    echo "阻断逻辑：${WINDOW_DURATION}秒窗口内出现 > ${TRIGGER_COUNT}次异常"
    echo "业务隔离：自动检测并排除 xray/sing-box 所有端口流量"
    echo "延时逻辑：阻断期内若检测到异常，自动延长阻断时间，直至比率恢复正常"
    echo "======================================"
    echo "1) 安装并启动监控"
    echo "2) TG通知设置"
    echo "3) 修改脚本参数"
    echo "4) 清理并复原"
    echo "5) 实时监控日志"
    echo "0) 退出"
    echo "======================================"
    read -rp "请输入选项 [0-5]: " choice
    case "$choice" in
        1) install_monitor ;;
        2) setup_tg ;;
        3) modify_params ;;
        4) remove_monitor ;;
        5) view_logs ;;
        0) exit 0 ;;
    esac
    read -p "按回车返回菜单..." 
done
