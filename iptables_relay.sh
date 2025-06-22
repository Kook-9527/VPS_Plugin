#!/bin/bash

# ANSI 颜色
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[36m"
RESET="\e[0m"

# 符号
TICK="${GREEN}✅${RESET}"
CROSS="${RED}❌${RESET}"
WARN="${YELLOW}⚠️${RESET}"
INFO="${BLUE}ℹ️${RESET}"

# 检查是否为 root
[[ "$EUID" -ne 0 ]] && echo -e "${CROSS} 请使用 root 用户运行此脚本。" && exit 1

IPTABLES=iptables
IP6TABLES=ip6tables

RULE_LIST=()

print_centered() {
    local text="$1"
    local width=$(tput cols)
    local pad=$(( (width - ${#text}) / 2 ))
    printf "%*s%s\n" "$pad" "" "$text"
}

clear_rules() {
    clear
    echo -e "╭────────────────────────────────────────────╮"
    echo -e "│                当前转发规则                │"
    echo -e "╰────────────────────────────────────────────╯"
    printf "%-5s │ %-4s │ %-5s │ %-30s │\n" "编号" "协议" "端口" "目标地址"
    echo "─────┼──────┼───────┼────────────────────────────────┤"
    RULE_LIST=()
    INDEX=1
    {
        $IPTABLES -t nat -S PREROUTING 2>/dev/null | grep 'DNAT' | grep -Eo '^-A PREROUTING -p (tcp|udp).*--dport [0-9]+.*--to-destination [^ ]+' | \
        while read -r line; do
            proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
            port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
            dst=$(echo "$line" | grep -oP '(?<=--to-destination )[^ ]+')
            echo "$proto $port $dst"
        done
        $IP6TABLES -t nat -S PREROUTING 2>/dev/null | grep 'DNAT' | grep -Eo '^-A PREROUTING -p (tcp|udp).*--dport [0-9]+.*--to-destination [^ ]+' | \
        while read -r line; do
            proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
            port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
            dst=$(echo "$line" | grep -oP '(?<=--to-destination )[^ ]+')
            echo "$proto $port $dst"
        done
    } | while read -r proto port dst; do
        printf "%-4s │ %-4s │ %-5s │ %-30s │\n" "$INDEX" "${proto^^}" "$port" "$dst"
        RULE_LIST+=("$proto $port $dst")
        INDEX=$((INDEX + 1))
    done
}

parse_target() {
    # 解析目标IP和端口，支持 IPv6 带中括号格式 [IPv6]:port
    local target="$1"
    local ip port

    if [[ "$target" =~ ^\[([^\]]+)\]:(.+)$ ]]; then
        ip="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$target" == *:*:* ]]; then
        # IPv6 无端口，直接取整个地址
        ip="$target"
        port=""
    elif [[ "$target" == *:* ]]; then
        ip="${target%:*}"
        port="${target##*:}"
    else
        ip="$target"
        port=""
    fi

    echo "$ip $port"
}

add_rule() {
    local proto="$1" port="$2" target="$3"
    local ip port tgt_port

    read ip port <<< "$(parse_target "$target")"
    [[ -z "$port" ]] && tgt_port="$port" || tgt_port="$port"

    if [[ -z "$port" ]]; then
        tgt_port="$port"
    else
        tgt_port="$port"
    fi

    if [[ -z "$tgt_port" ]]; then
        tgt_port="$port"
    fi

    [[ -z "$tgt_port" ]] && tgt_port="$port"

    # 端口优先用参数的 port
    [[ -z "$tgt_port" ]] && tgt_port="$port"

    [[ -z "$tgt_port" ]] && tgt_port="$port"

    # 防止 tgt_port 为空，取入参 port
    [[ -z "$tgt_port" ]] && tgt_port="$port"

    # IPv6 标记
    is_ipv6=0
    [[ "$ip" == *:* ]] && is_ipv6=1

    IPT=$([ "$is_ipv6" -eq 1 ] && echo $IP6TABLES || echo $IPTABLES)

    if $IPT -t nat -C PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$ip:$tgt_port" 2>/dev/null; then
        echo -e "${WARN} $proto/$port --> $ip:$tgt_port 已存在"
        return
    fi

    $IPT -t nat -A PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$ip:$tgt_port"
    $IPT -A FORWARD -s "$ip/$(($is_ipv6 ? 128 : 32))" -j ACCEPT 2>/dev/null || true
    $IPT -A FORWARD -d "$ip/$(($is_ipv6 ? 128 : 32))" -j ACCEPT 2>/dev/null || true
    $IPT -t nat -A POSTROUTING -d "$ip/$(($is_ipv6 ? 128 : 32))" -j MASQUERADE 2>/dev/null || true

    echo -e "${TICK} 添加成功：$proto/$port --> $ip:$tgt_port"
}

del_exact_rule() {
    local proto="$1" port="$2" target="$3"
    local ip port tgt_port

    read ip port <<< "$(parse_target "$target")"
    [[ -z "$port" ]] && tgt_port="$port" || tgt_port="$port"

    # IPv6 标记
    is_ipv6=0
    [[ "$ip" == *:* ]] && is_ipv6=1

    IPT=$([ "$is_ipv6" -eq 1 ] && echo $IP6TABLES || echo $IPTABLES)

    while $IPT -t nat -C PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$ip:$port" 2>/dev/null; do
        $IPT -t nat -D PREROUTING -p "$proto" --dport "$port" -j DNAT --to-destination "$ip:$port"
        echo -e "${TICK} 删除 $proto/$port --> $ip:$port"
    done

    if ! $IPT -t nat -S PREROUTING | grep -q "$ip"; then
        $IPT -D FORWARD -s "$ip/$(($is_ipv6 ? 128 : 32))" -j ACCEPT 2>/dev/null || true
        $IPT -D FORWARD -d "$ip/$(($is_ipv6 ? 128 : 32))" -j ACCEPT 2>/dev/null || true
        $IPT -t nat -D POSTROUTING -d "$ip/$(($is_ipv6 ? 128 : 32))" -j MASQUERADE 2>/dev/null || true
        echo -e "${TICK} 删除关联 FORWARD / POSTROUTING"
    fi
}

del_by_index() {
    local index="$1"
    if [[ "$index" -gt 0 && "$index" -le "${#RULE_LIST[@]}" ]]; then
        rule="${RULE_LIST[$((index - 1))]}"
        proto=$(echo "$rule" | awk '{print $1}')
        port=$(echo "$rule" | awk '{print $2}')
        target=$(echo "$rule" | awk '{print $3}')
        del_exact_rule "$proto" "$port" "$target"
    else
        echo -e "${CROSS} 无效的编号。"
    fi
}

del_by_pattern() {
    local proto="$1" ip="$2" port_filter="$3"
    for rule in "${RULE_LIST[@]}"; do
        rule_proto=$(echo "$rule" | awk '{print $1}')
        rule_port=$(echo "$rule" | awk '{print $2}')
        rule_target=$(echo "$rule" | awk '{print $3}')
        rule_ip="${rule_target%%:*}"
        rule_tgt_port="${rule_target##*:}"

        [[ "$proto" != "any" && "$rule_proto" != "$proto" ]] && continue
        [[ "$ip" != "$rule_ip" ]] && continue
        [[ -n "$port_filter" && "$port_filter" != "$rule_tgt_port" ]] && continue

        del_exact_rule "$rule_proto" "$rule_port" "$rule_target"
    done
}

main_loop() {
    while true; do
        echo
        printf "${BLUE}请输入指令（add/del 或 quit）：${RESET} "
        read -r cmd
        [[ "$cmd" =~ ^(q|quit|exit)$ ]] && echo -e "${TICK} 已退出。" && exit 0

        if [[ "$cmd" =~ ^add[[:space:]]+((tcp|udp)[[:space:]]+)?([0-9]+)[[:space:]]+([^\ ]+)$ ]]; then
            proto="${BASH_REMATCH[2]}"
            port="${BASH_REMATCH[3]}"
            target="${BASH_REMATCH[4]}"
            [[ -z "$proto" ]] && for p in tcp udp; do add_rule "$p" "$port" "$target"; done
            [[ -n "$proto" ]] && add_rule "$proto" "$port" "$target"
        elif [[ "$cmd" =~ ^del[[:space:]]+([0-9]+)$ ]]; then
            del_by_index "${BASH_REMATCH[1]}"
        elif [[ "$cmd" =~ ^del[[:space:]]+((tcp|udp)[[:space:]]+)?([^\ ]+)$ ]]; then
            proto="${BASH_REMATCH[2]}"
            target="${BASH_REMATCH[3]}"
            proto="${proto:-any}"
            if [[ "$target" == *:* ]]; then
                ip="${target%%:*}"
                port="${target##*:}"
            else
                ip="$target"
                port=""
            fi
            del_by_pattern "$proto" "$ip" "$port"
        else
            echo -e "${CROSS} 命令无效。格式示例："
            echo -e "  ${INFO} add tcp 80 1.1.1.1"
            echo -e "  ${INFO} add 443 [::1]:8443"
            echo -e "  ${INFO} del 2"
            echo -e "  ${INFO} del udp 1.1.1.1"
            echo -e "  ${INFO} del 1.1.1.1:443"
        fi

        echo; read -n1 -r -p "" ; echo
        clear_rules
    done
}

# 启动
clear_rules
main_loop