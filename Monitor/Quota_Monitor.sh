#!/bin/bash

CONFIG_FILE="/etc/quota_monitor.conf"
SCRIPT_PATH=$(readlink -f "$0")
SERVICE_NAME="quota-monitor.service"

# --- 默认参数 ---
DEFAULT_PORT=55555
DEFAULT_QUOTA_GB=300
DEFAULT_CYCLE_DAY="08"
DEFAULT_CYCLE_TIME="22:00:14"

# --- 环境加载 ---
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        BLOCK_PORT=$DEFAULT_PORT
        QUOTA_GB=$DEFAULT_QUOTA_GB
        CYCLE_DAY=$DEFAULT_CYCLE_DAY
        CYCLE_TIME=$DEFAULT_CYCLE_TIME
        BASE_MB=0
        HAS_BLOCKED=false
        LAST_RESET_MONTH=""
        TG_ENABLE="已关闭"
        TG_TOKEN=""
        TG_CHATID=""
        SERVER_NAME="未命名服务器"
        NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}' 2>/dev/null || echo "eth0")
    fi
}

save_config() {
    cat << EOF > "$CONFIG_FILE"
BLOCK_PORT="$BLOCK_PORT"
QUOTA_GB=$QUOTA_GB
CYCLE_DAY=$CYCLE_DAY
CYCLE_TIME=$CYCLE_TIME
BASE_MB=$BASE_MB
HAS_BLOCKED=$HAS_BLOCKED
LAST_RESET_MONTH=$LAST_RESET_MONTH
TG_ENABLE="$TG_ENABLE"
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
SERVER_NAME="$SERVER_NAME"
NET_INTERFACE=$NET_INTERFACE
EOF
}

# --- 核心通知函数 ---
send_tg() {
    if [ "$TG_ENABLE" == "已开启" ] && [ -n "$TG_TOKEN" ]; then
        local msg="$1"
        local time_now=$(date '+%Y-%m-%d %H:%M:%S')
        local text="🛡️ 流量配额通知%0A━━━━━━━━━━━━━━━%0A📌 服务器：$SERVER_NAME%0A📢 消息：$msg%0A⏰ 时间：$time_now"
        
        local retry=0
        while [ $retry -lt 3 ]; do
            local result=$(curl -s -m 10 --connect-timeout 5 -X POST \
                "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
                -d "chat_id=$TG_CHATID" \
                -d "text=$text" 2>&1)
            
            if echo "$result" | grep -q '"ok":true'; then
                return 0
            fi
            retry=$((retry + 1))
            [ $retry -lt 3 ] && sleep 3
        done
    fi
}

get_total_mb() {
    local total_mib=$(vnstat -i "$NET_INTERFACE" --json | jq '.interfaces[0].traffic.total.rx + .interfaces[0].traffic.total.tx' | awk '{printf "%.0f", $1/1024/1024}')
    
    if [[ -z "$total_mib" || "$total_mib" == "0" ]]; then
        local raw_total=$(vnstat -i "$NET_INTERFACE" --oneline | cut -d';' -f6)
        total_mib=$(echo "$raw_total" | awk '{
            if($2=="GiB") print $1*1024;
            else if($2=="MiB") print $1;
            else if($2=="TiB") print $1*1024*1024;
            else print $1/1024
        }' | cut -d. -f1)
    fi
    echo "${total_mib:-0}"
}

# --- 多端口封禁函数 ---
block_ports() {
    IFS=',' read -ra PORTS <<< "$BLOCK_PORT"
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        iptables -I INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
        iptables -I INPUT -p udp --dport "$port" -j DROP 2>/dev/null
        ip6tables -I INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
        ip6tables -I INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    done
}

# --- 多端口解封函数 ---
unblock_ports() {
    IFS=',' read -ra PORTS <<< "$BLOCK_PORT"
    for port in "${PORTS[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
        iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
        ip6tables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null
        ip6tables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null
    done
}

# --- 检查端口是否被封禁 ---
check_ports_blocked() {
    IFS=',' read -ra PORTS <<< "$BLOCK_PORT"
    local port=$(echo "${PORTS[0]}" | tr -d ' ')
    iptables -L INPUT -n 2>/dev/null | grep -q "dpt:$port.*DROP" && return 0 || return 1
}

# --- 后台逻辑 ---
run_monitor() {
    echo "[$(date '+%T')] 监控服务已启动..."
    sleep 5
    while true; do
        load_config
        CURRENT_TOTAL=$(get_total_mb)
        
        if [ "$CURRENT_TOTAL" -eq 0 ]; then
            sleep 30
            continue
        fi

        NOW_MONTH=$(date +%Y-%m)
        NOW_DAY=$(date +%d)
        NOW_HMS=$(date +%H:%M:%S)
        
        # 1. 重置逻辑
        if [ "$NOW_DAY" == "$CYCLE_DAY" ] && [[ "$NOW_HMS" > "$CYCLE_TIME" ]]; then
            if [ "$LAST_RESET_MONTH" != "$NOW_MONTH" ]; then
                BASE_MB=$CURRENT_TOTAL
                LAST_RESET_MONTH=$NOW_MONTH
                HAS_BLOCKED=false
                unblock_ports
                save_config
                send_tg "✅ 新周期已开始！端口 $BLOCK_PORT 已解封，流量统计已重置。"
                echo "[$(date '+%T')] 周期重置并发送通知。"
            fi
        fi

        # 2. 计算已用流量
        USED_MB=$((CURRENT_TOTAL - BASE_MB))
        [ $USED_MB -lt 0 ] && USED_MB=0
        USED_GB=$(echo "scale=4; $USED_MB / 1024" | bc)
        
        # 3. 封禁逻辑
        if (( $(echo "$USED_GB >= $QUOTA_GB" | bc -l) )); then
            if [ "$HAS_BLOCKED" = false ]; then
                block_ports
                HAS_BLOCKED=true
                save_config
                send_tg "🚫 流量超标告警%0A已使用：${USED_GB} GB%0A配额：${QUOTA_GB} GB%0A状态：已封锁端口 $BLOCK_PORT"
                echo "[$(date '+%T')] 流量达标，已封锁端口 $BLOCK_PORT"
            fi
        fi
        sleep 30
    done
}

# --- 交互菜单 ---
case "$1" in
    "run") run_monitor ;;
    *)
        while true; do
            load_config
            clear
            echo "========================================"
            echo " 流量配额精确监控 v1.0.1 | by：kook9527"
            echo " 周期：每月 $CYCLE_DAY 日 $CYCLE_TIME 重置"
            echo "========================================"
            
            CUR_M=$(get_total_mb)
            U_M=$((CUR_M - BASE_MB))
            [ $U_M -lt 0 ] && U_M=0
            U_GB=$(echo "scale=2; $U_M / 1024" | bc)
            ST_RUN=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "运行中" || echo "未启动")

            echo " 脚本状态：$ST_RUN 丨 TG通知：$TG_ENABLE"
            echo " 监控网卡：$NET_INTERFACE 丨 限制端口：$BLOCK_PORT"
            echo " 流量配额：$U_GB GB / $QUOTA_GB GB "
            echo -n " 端口状态："
            if check_ports_blocked; then
                echo -e "\033[31m[已封禁]\033[0m"
            else
                echo -e "\033[32m[正常]\033[0m"
            fi
            echo "========================================"
            echo "1) 安装并启动监控"
            echo "2) TG通知设置"
            echo "3) 修改脚本参数"
            echo "4) 查看实时日志"
            echo "5) 手动解封端口"
            echo "6) 清理并复原"
            echo "0) 退出"
            echo "========================================"
            read -rp "请输入选项 [0-6]: " choice

            case "$choice" in
                1)
                    echo "提示：端口支持多个，用逗号分隔，如：55555,55556,55557"
                    read -rp "请输入要限制的端口 [默认 $DEFAULT_PORT]: " USER_PORT
                    BLOCK_PORT="${USER_PORT:-$DEFAULT_PORT}"
                    
                    apt update && apt install -y jq vnstat bc curl
                    systemctl enable --now vnstat
                    vnstat -i "$NET_INTERFACE" --add >/dev/null 2>&1
                    BASE_MB=$(get_total_mb)
                    LAST_RESET_MONTH=$(date +%Y-%m)
                    save_config
                    
                    cat << EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Quota Monitor
After=network.target vnstat.service

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH run
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
                    systemctl daemon-reload
                    systemctl restart $SERVICE_NAME
                    
                    echo "✅ 核心服务安装成功！"
                    echo "--- TG 通知配置 ---"
                    read -rp "是否配置 TG 通知? [Y/n]: " tg_c; tg_c=${tg_c:-y}
                    if [[ "$tg_c" == [yY] ]]; then
                        read -rp "请输入服务器备注名称: " SERVER_NAME
                        read -rp "请输入TG机器人Token: " TG_TOKEN
                        read -rp "请输入TG账号ID: " TG_CHATID
                        TG_ENABLE="已开启"
                        save_config
                        send_tg "🎉 监控服务连接成功！此后将通过此机器人发送通知。"
                        systemctl restart $SERVICE_NAME
                    fi
                    ;;
                2)
                    read -rp "请输入服务器备注名称: " SERVER_NAME
                    read -rp "请输入TG机器人Token: " TG_TOKEN
                    read -rp "请输入TG账号ID: " TG_CHATID
                    TG_ENABLE="已开启"; save_config
                    send_tg "✅ TG 通知设置已更新！"
                    systemctl restart $SERVICE_NAME
                    ;;
                3)
                    echo "============================="
                    echo "       修改运行参数"
                    echo "============================="
                    echo "提示：端口支持多个，用逗号分隔，如：55555,55556,55557"
                    read -rp "1. 限制端口 [当前: $BLOCK_PORT]: " input; BLOCK_PORT=${input:-$BLOCK_PORT}
                    read -rp "2. 流量配额 GB [当前: $QUOTA_GB]: " input; QUOTA_GB=${input:-$QUOTA_GB}
                    read -rp "3. 重置日期(每月几号) [当前: $CYCLE_DAY]: " input; CYCLE_DAY=${input:-$CYCLE_DAY}
                    read -rp "4. 重置时间(HH:MM:SS) [当前: $CYCLE_TIME]: " input; CYCLE_TIME=${input:-$CYCLE_TIME}
                    read -rp "5. 监控网卡 [当前: $NET_INTERFACE]: " input; NET_INTERFACE=${input:-$NET_INTERFACE}
                    save_config
                    systemctl restart $SERVICE_NAME 2>/dev/null
                    echo "✅ 参数已保存并应用。"
                    ;;
                4) journalctl -u $SERVICE_NAME -f -n 20 ;;
                5)
                    unblock_ports
                    HAS_BLOCKED=false
                    save_config
                    echo "✅ 已手动解封端口：$BLOCK_PORT"
                    ;;
                6)
                    systemctl stop $SERVICE_NAME 2>/dev/null
                    systemctl disable $SERVICE_NAME 2>/dev/null
                    rm -f /etc/systemd/system/$SERVICE_NAME "$CONFIG_FILE"
                    unblock_ports
                    echo "✅ 已清理所有配置和规则。"
                    ;;
                0) exit 0 ;;
            esac
            read -p "按回车返回菜单..."
        done
        ;;
esac
