#!/bin/bash

CONFIG_FILE="/etc/quota_monitor.conf"
# 自动获取脚本当前的绝对路径，解决 status 203 报错
SCRIPT_PATH=$(readlink -f "$0")
SERVICE_NAME="quota-monitor.service"

# --- 默认参数 ---
DEFAULT_PORT=55555
DEFAULT_QUOTA_GB=300
DEFAULT_CYCLE_DAY="08"
DEFAULT_CYCLE_TIME="22:00:14"

# --- 加载配置 ---
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        BLOCK_PORT=$DEFAULT_PORT
        QUOTA_GB=$DEFAULT_QUOTA_GB
        CYCLE_DAY=$DEFAULT_CYCLE_DAY
        CYCLE_TIME=$DEFAULT_CYCLE_TIME
        BASE_BYTES=0
        HAS_BLOCKED=false
        LAST_RESET_MONTH=""
        TG_ENABLE="已关闭"
        TG_TOKEN=""
        TG_CHATID=""
        SERVER_NAME="未命名服务器"
        NET_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    fi
}

save_config() {
    cat << EOF > "$CONFIG_FILE"
BLOCK_PORT=$BLOCK_PORT
QUOTA_GB=$QUOTA_GB
CYCLE_DAY=$CYCLE_DAY
CYCLE_TIME=$CYCLE_TIME
BASE_BYTES=$BASE_BYTES
HAS_BLOCKED=$HAS_BLOCKED
LAST_RESET_MONTH=$LAST_RESET_MONTH
TG_ENABLE="$TG_ENABLE"
TG_TOKEN="$TG_TOKEN"
TG_CHATID="$TG_CHATID"
SERVER_NAME="$SERVER_NAME"
NET_INTERFACE=$NET_INTERFACE
EOF
}

# --- 功能函数 ---
install_deps() {
    echo "正在检查并安装必要依赖 (vnstat, bc, curl)..."
    apt update -y || yum check-update
    apt install -y vnstat bc curl || yum install -y vnstat bc curl
    systemctl enable --now vnstat
    # 兼容性处理：尝试初始化，如果报错则跳过
    vnstat -i "$NET_INTERFACE" >/dev/null 2>&1
}

setup_tg() {
    echo "--- TG 通知配置 ---"
    read -rp "是否开启/配置 TG 通知? [Y/n]: " tg_choice
    tg_choice=${tg_choice:-y}
    if [[ "$tg_choice" == [yY] ]]; then
        read -rp "请输入服务器备注名称: " SERVER_NAME
        read -rp "请输入TG机器人Token: " TG_TOKEN
        read -rp "请输入TG账号ID: " TG_CHATID
        TG_ENABLE="已开启"
        echo "✅ TG 配置已记录。"
    else
        TG_ENABLE="已关闭"
        echo "ℹ️ 已跳过 TG 配置。"
    fi
    save_config
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME"
    fi
}

send_tg() {
    [ "$TG_ENABLE" != "已开启" ] && return
    local msg="$1"
    local time_now=$(date '+%Y-%m-%d %H:%M:%S')
    local text="🛡️ **流量配额通知**%0A服务器：$SERVER_NAME%0A消息：$msg%0A时间：$time_now"
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHATID" -d "text=$text" > /dev/null
}

get_total_bytes() {
    # 确保 vnstat 有数据输出
    local data=$(vnstat -i "$NET_INTERFACE" --json 2>/dev/null)
    if [ -z "$data" ]; then
        echo "0"
        return
    fi
    local rx=$(echo "$data" | grep -m 1 '"rx":' | awk '{print $2}' | tr -d ',')
    local tx=$(echo "$data" | grep -m 1 '"tx":' | awk '{print $2}' | tr -d ',')
    echo $((rx + tx))
}

run_monitor() {
    while true; do
        load_config
        CURRENT_TOTAL=$(get_total_bytes)
        NOW_MONTH=$(date +%Y-%m)
        NOW_DAY=$(date +%d)
        NOW_HMS=$(date +%H:%M:%S)
        
        if [ "$NOW_DAY" == "$CYCLE_DAY" ] && [[ "$NOW_HMS" > "$CYCLE_TIME" ]]; then
            if [ "$LAST_RESET_MONTH" != "$NOW_MONTH" ]; then
                BASE_BYTES=$CURRENT_TOTAL
                LAST_RESET_MONTH=$NOW_MONTH
                HAS_BLOCKED=false
                iptables -D INPUT -p tcp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
                iptables -D INPUT -p udp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
                save_config
                send_tg "✅ 新周期开始，已重置流量并解封端口 $BLOCK_PORT"
                echo "[$(date '+%T')] 新周期重置：已解封端口并更新基准。"
            fi
        fi

        USED_BYTES=$((CURRENT_TOTAL - BASE_BYTES))
        [ $USED_BYTES -lt 0 ] && USED_BYTES=0
        USED_GB=$(echo "scale=4; $USED_BYTES / 1024 / 1024 / 1024" | bc)
        
        if (( $(echo "$USED_GB >= $QUOTA_GB" | bc -l) )); then
            if [ "$HAS_BLOCKED" = false ]; then
                iptables -I INPUT -p tcp --dport "$BLOCK_PORT" -j DROP
                iptables -I INPUT -p udp --dport "$BLOCK_PORT" -j DROP
                HAS_BLOCKED=true
                save_config
                send_tg "🚫 流量已达 ${USED_GB}GB，已阻断端口 $BLOCK_PORT"
                echo "[$(date '+%T')] 流量超标：已封锁端口 $BLOCK_PORT。"
            fi
        fi
        sleep 30
    done
}

while true; do
    load_config
    clear
    echo "============================="
    echo " 流量配额精确监控 v1.5"
    echo " 周期：每月 $CYCLE_DAY 日 $CYCLE_TIME 重置"
    echo "============================="
    
    CUR_T=$(get_total_bytes)
    U_B=$((CUR_T - BASE_BYTES))
    [ $U_B -lt 0 ] && U_B=0
    U_GB=$(echo "scale=2; $U_B / 1024 / 1024 / 1024" | bc)
    ST_RUN=$(systemctl is-active --quiet "$SERVICE_NAME" && echo "运行中" || echo "未启动")

    echo " 脚本状态：$ST_RUN 丨 TG通知：$TG_ENABLE"
    echo " 监控网卡：$NET_INTERFACE 丨 限制端口：$BLOCK_PORT"
    echo " 流量配额：$U_GB GB / $QUOTA_GB GB "
    echo " 端口状态：$(iptables -L INPUT -n | grep -q "dpt:$BLOCK_PORT" && echo -e "\033[31m[已封禁]\033[0m" || echo -e "\033[32m[正常]\033[0m")"
    echo "============================="
    echo "1) 安装并启动监控"
    echo "2) TG通知设置"
    echo "3) 修改脚本参数"
    echo "4) 查看实时日志"
    echo "5) 手动解封端口"
    echo "6) 清理并复原"
    echo "0) 退出"
    echo "============================="
    read -rp "请输入选项 [0-6]: " choice

    case "$choice" in
        1)
            install_deps
            BASE_BYTES=$(get_total_bytes)
            LAST_RESET_MONTH=$(date +%Y-%m)
            save_config
            cat << EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=Precise Quota Monitor
After=network.target vnstat.service

[Service]
ExecStart=$SCRIPT_PATH run
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now $SERVICE_NAME
            echo "✅ 核心服务安装成功！"
            setup_tg
            ;;
        2) setup_tg ;;
        3)
            echo "--- 修改参数 (回车保持当前) ---"
            read -rp "限额端口 [$BLOCK_PORT]: " p; BLOCK_PORT=${p:-$BLOCK_PORT}
            read -rp "流量配额GB [$QUOTA_GB]: " q; QUOTA_GB=${q:-$QUOTA_GB}
            read -rp "重置日期(01-31) [$CYCLE_DAY]: " d; CYCLE_DAY=${d:-$CYCLE_DAY}
            read -rp "重置时间 [$CYCLE_TIME]: " t; CYCLE_TIME=${t:-$CYCLE_TIME}
            save_config
            systemctl restart $SERVICE_NAME 2>/dev/null
            echo "✅ 参数更新成功"
            ;;
        4) journalctl -u $SERVICE_NAME -f -n 20 ;;
        5)
            iptables -D INPUT -p tcp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
            iptables -D INPUT -p udp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
            HAS_BLOCKED=false
            save_config
            echo "✅ 端口已解封"
            ;;
        6)
            systemctl stop $SERVICE_NAME 2>/dev/null
            systemctl disable $SERVICE_NAME 2>/dev/null
            rm -f /etc/systemd/system/$SERVICE_NAME "$CONFIG_FILE"
            iptables -D INPUT -p tcp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
            iptables -D INPUT -p udp --dport "$BLOCK_PORT" -j DROP 2>/dev/null
            echo "✅ 已卸载"
            ;;
        0) exit 0 ;;
        run) run_monitor ;;
    esac
    read -p "按回车返回菜单..."
done
