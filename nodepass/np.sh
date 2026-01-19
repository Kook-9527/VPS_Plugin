#!/usr/bin/env bash

# 脚本版本号
SCRIPT_VERSION='0.0.1'

export DEBIAN_FRONTEND=noninteractive
TEMP_DIR='/tmp/nodepass'
WORK_DIR='/etc/nodepass'

# 退出清理
trap "rm -rf $TEMP_DIR >/dev/null 2>&1 ; echo -e '\n' ;exit" INT QUIT TERM EXIT
mkdir -p $TEMP_DIR

# --- 完整的交互语言包 (确保交互信息丰富) ---
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

# 颜色函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }
reading() { read -rp "$(info "$1")" "$2"; }
text() { eval echo "\"\${C[$*]}\""; }

# --- 核心：根据你 journalctl -f 的日志精准提取 ---
get_api_key() {
    GLOBAL_KEY=""
    # 针对日志: API Key created: b1c1ae63870c7c8d8bfed47f4fd0766c
    # 增加到 10 次循环，确保刚启动时日志能写进去
    for i in {1..10}; do
        GLOBAL_KEY=$(journalctl -u nodepass --no-pager -n 100 2>/dev/null | \
                     sed 's/\x1b\[[0-9;]*m//g' | \
                     grep "API Key created" | \
                     grep -oE '[a-f0-9]{32}' | tail -n1)
        
        if [ -n "$GLOBAL_KEY" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- 核心：显示详细配置信息 (含带 Key 的二维码) ---
display_full_info() {
    [ -s "$WORK_DIR/data" ] && source "$WORK_DIR/data"
    
    # 1. 强制先获取 KEY
    get_api_key
    
    # 2. 格式化输出
    [[ "$SERVER_IP" =~ ':' ]] && IP_F="[$SERVER_IP]" || IP_F="$SERVER_IP"
    [ "$TLS_MODE" = 0 ] || [ -z "$TLS_MODE" ] && PROTO="http" || PROTO="https"
    API_URL="$PROTO://$IP_F:$PORT/${PREFIX%/}/v1"
    
    # 3. 构造带 Key 的协议 URI
    if [ -n "$GLOBAL_KEY" ]; then
        # 协议格式：np://master?url=[BASE64_URL]&key=[KEY]
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
        warning "$(text 40) 提取失败，请检查 [ journalctl -u nodepass ] 确认是否有 KEY 产生"
    fi
    info "$(text 90) $URI"
    [ -x "$WORK_DIR/qrencode" ] && "$WORK_DIR/qrencode" "$URI"
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
  curl -fsSL -o "$TEMP_DIR/qrencode" "https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$ARCH"
  chmod +x "$TEMP_DIR/nodepass" "$TEMP_DIR/qrencode"

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

  mkdir -p "$WORK_DIR" && mv "$TEMP_DIR/nodepass" "$WORK_DIR/" && mv "$TEMP_DIR/qrencode" "$WORK_DIR/"
  
  echo "SERVER_IP='$SERVER_IP'
PORT='$PORT'
PREFIX='$PREFIX'
TLS_MODE='$TLS_MODE'" > "$WORK_DIR/data"

  # 写入服务
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

  # 写入全局命令
  echo -e "#!/bin/bash\nbash <(curl -fsSL https://raw.githubusercontent.com/Kook-9527/VPS_Plugin/main/nodepass/np.sh) \"\$@\"" > /usr/bin/np
  chmod +x /usr/bin/np

  info "$(text 10)"
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
    hint " 基础 API: http://$SERVER_IP:$PORT/$PREFIX/v1"
    echo "------------------------"
    hint "1. 开关服务\n2. 卸载 NodePass\n3. 查看详细信息(二维码含Key)\n0. 退出"
    reading "$(text 38)" choice
    case "$choice" in
      1) pgrep -f nodepass >/dev/null && systemctl stop nodepass || systemctl start nodepass; menu ;;
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

# --- 脚本入口 ---
[ "$(id -u)" != 0 ] && error "$(text 2)"
case "$1" in
  -s) display_full_info ;;
  *) menu ;;
esac
