#!/usr/bin/env bash

# 脚本版本号
SCRIPT_VERSION='0.0.1'
export DEBIAN_FRONTEND=noninteractive
TEMP_DIR='/tmp/nodepass'
WORK_DIR='/etc/nodepass'

# 退出清理
trap "rm -rf $TEMP_DIR >/dev/null 2>&1 ; echo -e '\n' ;exit" INT QUIT TERM EXIT
mkdir -p $TEMP_DIR

# --- 完整的交互语言包 ---
C[2]="必须以 root 方式运行脚本"
C[3]="不支持的架构: $(uname -m)"
C[5]="本脚本只支持 Linux 系统"
C[9]="下载失败"
C[10]="NodePass 安装成功！"
C[11]="NodePass 已卸载"
C[13]="请输入端口 (1024-65535，回车随机):"
C[14]="请输入 API 前缀 (回车使用默认 \"api\"):"
C[15]="请选择 TLS 模式 (回车不使用 TLS):"
C[16]="0. 不使用 TLS (默认)\n1. 自签名证书\n2. 自定义证书"
C[32]="未安装"
C[33]="已停止"
C[34]="运行中"
C[35]="NodePass 安装信息:"
C[36]="端口已被占用，请尝试其他端口。"
C[37]="使用随机端口:"
C[38]="请选择: "
C[39]="API URL:"
C[40]="API KEY:"
C[51]="启动 NodePass 服务..."
C[78]="检测到本机 IP 地址如下:"
C[79]="请选择编号，或直接输入域名/IP:"
C[85]="获取机器 IP 地址中..."
C[90]="NodePass URI:"
C[91]="自动提取 API Key 失败，正在尝试更长的等待时间..."
C[92]="仍未提取到 API Key，请手动从日志复制（命令：journalctl -u nodepass | grep -i key）"
C[93]="请输入 API Key（32位十六进制，直接回车跳过将不包含Key）:"

# 颜色函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }
reading() { read -rp "$(info "$1")" "$2"; }
text() { eval echo "\"\${C[$*]}\""; }

# --- 改进的 API Key 提取 ---
get_api_key() {
    GLOBAL_KEY=""
    for i in {1..15}; do
        GLOBAL_KEY=$(journalctl -u nodepass --no-pager -n 1000 2>/dev/null | \
                     sed 's/\x1b\[[0-9;]*m//g' | \
                     grep -iE "(API Key|key created|generated|master key)" | \
                     grep -oE '[a-f0-9]{32}' | tail -n1)
        [ -n "$GLOBAL_KEY" ] && return 0
        sleep 1
    done

    info "$(text 91)"
    for i in {1..30}; do
        GLOBAL_KEY=$(journalctl -u nodepass --no-pager -n 2000 2>/dev/null | \
                     sed 's/\x1b\[[0-9;]*m//g' | \
                     grep -iE "(API Key|key created|generated|master key)" | \
                     grep -oE '[a-f0-9]{32}' | tail -n1)
        [ -n "$GLOBAL_KEY" ] && return 0
        sleep 1
    done
    return 1
}

# --- 显示详细信息：只显示文本信息（无二维码） ---
display_full_info() {
    [ -s "$WORK_DIR/data" ] && source "$WORK_DIR/data"
    
    if [ -n "$GLOBAL_KEY" ]; then
        info "使用已保存的 API Key"
    else
        info "正在尝试自动提取 API Key（最多等待约45秒）..."
        if get_api_key; then
            echo "GLOBAL_KEY='$GLOBAL_KEY'" >> "$WORK_DIR/data"
            info "API Key 自动提取成功并已永久保存！"
        else
            warning "$(text 92)"
            reading "$(text 93)" input_key
            if [[ "$input_key" =~ ^[a-f0-9]{32}$ ]]; then
                GLOBAL_KEY="$input_key"
                echo "GLOBAL_KEY='$GLOBAL_KEY'" >> "$WORK_DIR/data"
                info "已使用手动输入的 API Key 并永久保存！"
            else
                warning "未输入有效 Key，URI 将不包含 Key"
                GLOBAL_KEY=""
            fi
        fi
    fi

    [[ "$SERVER_IP" =~ ':' ]] && IP_F="[$SERVER_IP]" || IP_F="$SERVER_IP"
    [ "$TLS_MODE" = 0 ] || [ -z "$TLS_MODE" ] && PROTO="http" || PROTO="https"
    API_URL="$PROTO://$IP_F:$PORT/${PREFIX%/}/v1"
    
    if [ -n "$GLOBAL_KEY" ]; then
        URI="np://master?url=$(echo -n "$API_URL" | base64 -w0)&key=$GLOBAL_KEY"
    else
        URI="np://master?url=$(echo -n "$API_URL" | base64 -w0)"
    fi

    echo "----------------------------------------------------"
    info "$(text 35)"
    info "$(text 39) $API_URL"
    if [ -n "$GLOBAL_KEY" ]; then
        info "$(text 40) $GLOBAL_KEY"
    else
        warning "$(text 40) 无（客户端需手动填写）"
    fi
    info "$(text 90) $URI"
    echo "（可复制以上 URI 到客户端手动导入）"
    echo "----------------------------------------------------"
}

fetch_ip() {
    local family=$1
    local res=$(ip -$family route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [ -z "$res" ] && res=$(curl -$family -s --connect-timeout 5 http://api.ip.sb/ip 2>/dev/null)
    echo "$res"
}

install() {
  pkill -9 nodepass 2>/dev/null
  ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
  
  info "正在下载程序文件..."
  curl -fsSL -o "$TEMP_DIR/nodepass.tar.gz" "https://github.com/Kook-9527/VPS_Plugin/raw/refs/heads/main/nodepass/nodepass_1.14.3_linux_$ARCH.tar.gz"
  tar -xzf "$TEMP_DIR/nodepass.tar.gz" -C "$TEMP_DIR"

  # 已移除 qrencode 下载（不再需要二维码）

  chmod +x "$TEMP_DIR/nodepass"

  info "$(text 85)"
  IPV4=$(fetch_ip 4); IPV6=$(fetch_ip 6)

  if [ -n "$IPV4" ] && [ -n "$IPV6" ]; then
    hint "$(text 78)"
    echo -e " 1. ${IPV4} (IPv4)\n 2. ${IPV6} (IPv6)\n 3. 127.0.0.1"
    reading "$(text 79)" choice
    case "$choice" in 2) SERVER_IP="$IPV6" ;; 3) SERVER_IP="127.0.0.1" ;; *) SERVER_IP="$IPV4" ;; esac
  else
    SERVER_IP="${IPV4}${IPV6}"
    reading "确认 IP 地址: $SERVER_IP (直接回车确认): " input
    [ -n "$input" ] && SERVER_IP="$input"
  fi

  while :; do
    reading "$(text 13)" PORT
    [ -z "$PORT" ] && PORT=$((RANDOM % 7169 + 1024)) && info "$(text 37) $PORT"
    ss -tln | grep -q ":$PORT " && warning "$(text 36)" || break
  done

  reading "$(text 14)" PREFIX
  [ -z "$PREFIX" ] && PREFIX="api"
  PREFIX=$(echo "$PREFIX" | sed 's#^/##;s#/$##')

  hint "$(text 16)"
  reading "$(text 38)" TLS_MODE
  TLS_MODE=${TLS_MODE:-0}

  mkdir -p "$WORK_DIR" && mv "$TEMP_DIR/nodepass" "$WORK_DIR/"
  
  echo "SERVER_IP='$SERVER_IP'
PORT='$PORT'
PREFIX='$PREFIX'
TLS_MODE='$TLS_MODE'" > "$WORK_DIR/data"

  cat > /etc/systemd/system/nodepass.service <<EOF
[Unit]
Description=NodePass Service
After=network.target
[Service]
ExecStart=$WORK_DIR/nodepass "master://:$PORT/$PREFIX?tls=$TLS_MODE"
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now nodepass >/dev/null 2>&1

  echo -e "#!/bin/bash\nbash <(curl -fsSL https://raw.githubusercontent.com/Kook-9527/VPS_Plugin/main/nodepass/np.sh) \"\$@\"" > /usr/bin/np
  chmod +x /usr/bin/np

  info "$(text 10)"
  sleep 10
  display_full_info
}

menu() {
  clear
  echo "
╭───────────────────────────────────────────╮
│    ░░█▀█░█▀█░░▀█░█▀▀░█▀█░█▀█░█▀▀░█▀▀░░    │
│    ░░█░█░█░█░█▀█░█▀▀░█▀▀░█▀█░▀▀█░▀▀█░░    │
│    ░░▀░▀░▀▀▀░▀▀▀░▀▀▀░▀░░░▀░▀░▀▀▀░▀▀▀░░    │
├───────────────────────────────────────────┤
│   >Universal TCP/UDP Tunneling Solution   │
╰───────────────────────────────────────────╯ "
  info " 当前版本: v1.14.3 | 脚本版本: $SCRIPT_VERSION"

  if [ -f "$WORK_DIR/nodepass" ]; then
    pgrep -f nodepass >/dev/null && STATUS="$(text 34)" || STATUS="$(text 33)"
    info " NodePass: $STATUS"
    [ -s "$WORK_DIR/data" ] && source "$WORK_DIR/data"

    # 计算正确的 API URL（支持 IPv6 方括号和 TLS）
    [[ "$SERVER_IP" =~ ':' ]] && IP_F="[$SERVER_IP]" || IP_F="$SERVER_IP"
    [ "$TLS_MODE" = 0 ] || [ -z "$TLS_MODE" ] && PROTO="http" || PROTO="https"
    API_URL="$PROTO://$IP_F:$PORT/${PREFIX%/}/v1"

    hint " API URL: $API_URL"
    if [ -n "$GLOBAL_KEY" ]; then
        hint " API KEY: $GLOBAL_KEY"
    else
        warning " API KEY: 未获取（可进入选项3尝试提取或手动输入）"
    fi

    echo "------------------------"
    hint "1. 开关服务\n2. 卸载 NodePass\n3. 查看完整连接URI\n0. 退出"
    reading "$(text 38)" choice
    case "$choice" in
      1) pgrep -f nodepass >/dev/null && systemctl stop nodepass || systemctl start nodepass; sleep 8; menu ;;
      2) systemctl stop nodepass; rm -rf "$WORK_DIR" /usr/bin/np /etc/systemd/system/nodepass.service; systemctl daemon-reload; info "$(text 11)"; exit ;;
      3) display_full_info ;;
      0) exit ;;
      *) menu ;;
    esac
  else
    info " NodePass: $(text 32)"
    echo "------------------------"
    hint "1. 安装 NodePass\n0. 退出"
    reading "$(text 38)" choice
    [ "$choice" == "1" ] && install || exit
  fi
}

[ "$(id -u)" != 0 ] && error "$(text 2)"
case "$1" in
  -s) display_full_info ;;
  *) menu ;;
esac
