#!/usr/bin/env bash

# 当前脚本版本号
SCRIPT_VERSION='0.2.4-variable-fix'

export DEBIAN_FRONTEND=noninteractive

TEMP_DIR='/tmp/nodepass'
WORK_DIR='/etc/nodepass'

trap "rm -rf $TEMP_DIR >/dev/null 2>&1 ; echo -e '\n' ;exit" INT QUIT TERM EXIT

mkdir -p $TEMP_DIR

# --- 提示字符串修复：删除里面的变量占位符，由函数动态拼接 ---
C[2]="必须以 root 方式运行脚本，可以输入 sudo -i 后重新下载运行"
C[3]="不支持的架构: $(uname -m)"
C[5]="本脚本只支持 Linux 系统"
C[9]="下载失败"
C[10]="NodePass 安装成功！"
C[11]="NodePass 已卸载"
C[13]="请输入端口 (1024-65535，NAT 机器必须使用开放的端口，回车使用随机端口):"
C[14]="请输入 API 前缀 (仅限小写字母、数字和斜杠/，回车使用默认 \"api\"):"
C[15]="请选择 TLS 模式 (回车不使用 TLS 加密):"
C[16]="0. 不使用 TLS 加密（明文 TCP） - 最快性能，无开销（默认）\n1. 自签名证书（自动生成）\n2. 自定义证书（须预备 crt 和 key 文件）"
C[18]="NodePass 已安装，请先卸载后再重新安装"
C[19]="已下载 NodePass v1.14.3 和 QRencode"
C[23]="请输入您的 TLS 证书文件路径:"
C[24]="请输入您的 TLS 私钥文件路径:"
C[25]="证书文件不存在"
C[26]="私钥文件不存在"
C[27]="使用自定义 TLS 证书"
C[32]="未安装"
C[33]="已停止"
C[34]="运行中"
C[35]="NodePass 安装信息:"
C[36]="端口已被占用，请尝试其他端口。"
C[37]="使用随机端口:"
C[38]="请选择: "
C[39]="API URL:"
C[40]="API KEY:"
C[41]="无效的端口号，请输入1024到65535之间的数字。"
C[42]="NodePass 服务已关闭"
C[43]="NodePass 服务已开启"
C[50]="停止 NodePass 服务..."
C[51]="启动 NodePass 服务..."
C[57]="创建快捷方式成功: 脚本可通过 [ np ] 命令运行，[ nodepass ] 应用可直接执行!"
C[61]="PREFIX 只能包含小写字母、数字和斜杠(/)，请重新输入"
C[74]="不是有效的IPv4、IPv6地址或域名"
C[78]="检测到本机的外网地址如下:"
C[79]="请选择编号，或者直接输入域名/IP:"
C[85]="获取机器 IP 地址中..."
C[90]="NodePass URI:"

# 颜色函数
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error() { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info() { echo -e "\033[32m\033[01m$*\033[0m"; }
hint() { echo -e "\033[33m\033[01m$*\033[0m"; }
reading() { read -rp "$(info "$1")" "$2"; }
text() { eval echo "\"\${C[$*]}\""; }

check_root() { [ "$(id -u)" != 0 ] && error "$(text 2)"; }

check_system() {
  [ "$(uname -s)" != "Linux" ] && error "$(text 5)"
  case "$(uname -m)" in
    x86_64 | amd64 ) ARCH=amd64 ;;
    armv8 | arm64 | aarch64 ) ARCH=arm64 ;;
    armv7l ) ARCH=arm ;;
    * ) error "$(text 3)" ;;
  esac
  [ -x "$(type -p systemctl)" ] && SERVICE_MANAGE="systemctl" || SERVICE_MANAGE="none"
}

check_dependencies() {
  if [ -x "$(type -p curl)" ]; then
    DOWNLOAD_CMD="curl -fsSL --retry 3 --connect-timeout 5"
  else
    apt-get update && apt-get install -y curl
    DOWNLOAD_CMD="curl -fsSL --retry 3 --connect-timeout 5"
  fi
}

# 核心 IP 获取修复
fetch_ip() {
    local family=$1
    local res=""
    # 尝试多种方式获取，避免空结果
    if [ "$family" = "4" ]; then
        res=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        [ -z "$res" ] && res=$($DOWNLOAD_CMD -4 http://api.ip.sb/ip 2>/dev/null)
    else
        res=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
        [ -z "$res" ] && res=$($DOWNLOAD_CMD -6 http://api.ip.sb/ip 2>/dev/null)
    fi
    echo "$res"
}

get_api_url() {
  [ -s "$WORK_DIR/data" ] && source "$WORK_DIR/data"
  if [ -n "$PORT" ] && [ -n "$PREFIX" ]; then
    [ "$TLS_MODE" = 0 ] && PROTO="http" || PROTO="https"
    [[ "$SERVER_IP" =~ ':' ]] && SERVER_IP_SHOW="[$SERVER_IP]" || SERVER_IP_SHOW="$SERVER_IP"
    API_URL="$PROTO://$SERVER_IP_SHOW:$PORT/${PREFIX%/}/v1"
    [ "$1" = "output" ] && info "$(text 39) $API_URL"
  fi
}

get_api_key() {
  if [ "$1" = "output" ]; then
    local KEY=""
    if [ "$SERVICE_MANAGE" = "systemctl" ]; then
        KEY=$(journalctl -u nodepass --no-pager -n 50 2>/dev/null | grep -oE 'KEY=[a-zA-Z0-9]{8,}' | cut -d= -f2 | tail -n1)
    fi
    [ -z "$KEY" ] && KEY=$(pgrep -a nodepass | grep -oE 'KEY=[a-zA-Z0-9]{8,}' | cut -d= -f2 | tail -n1)
    [ -n "$KEY" ] && info "$(text 40) $KEY" || info "$(text 40) 获取中，请稍后 np -s 查看"
  fi
}

get_uri() {
  get_api_url
  if [ -n "$API_URL" ]; then
    URI="np://master?url=$(echo -n "$API_URL" | base64 -w0)"
    [ "$1" = "output" ] && info "$(text 90) $URI" && [ -x "$WORK_DIR/qrencode" ] && "$WORK_DIR/qrencode" "$URI"
  fi
}

start_nodepass() {
  info "$(text 51)"
  if [ "$SERVICE_MANAGE" = "systemctl" ]; then
    systemctl restart nodepass >/dev/null 2>&1
  else
    pkill -9 nodepass 2>/dev/null
    nohup "$WORK_DIR/nodepass" "$CMD" >/dev/null 2>&1 &
  fi
  sleep 3
}

install() {
  pkill -9 nodepass 2>/dev/null
  
  NODEPASS_TAR="$TEMP_DIR/nodepass.tar.gz"
  NODEPASS_URL="https://github.com/Kook-9527/VPS_Plugin/raw/refs/heads/main/nodepass/nodepass_1.14.3_linux_$ARCH.tar.gz"

  info "正在下载文件..."
  $DOWNLOAD_CMD -o "$NODEPASS_TAR" "$NODEPASS_URL" || error "$(text 9)"
  tar -xzf "$NODEPASS_TAR" -C "$TEMP_DIR"
  $DOWNLOAD_CMD -o "$TEMP_DIR/qrencode" "https://github.com/fscarmen/client_template/raw/main/qrencode-go/qrencode-go-linux-$ARCH"
  chmod +x "$TEMP_DIR/qrencode" "$TEMP_DIR/nodepass"

  info "$(text 19)"
  info "$(text 85)"

  SERVER_IPV4_DEFAULT=$(fetch_ip 4)
  SERVER_IPV6_DEFAULT=$(fetch_ip 6)

  # --- 修复变量无法显示的问题 ---
  if [ -n "$SERVER_IPV4_DEFAULT" ] && [ -n "$SERVER_IPV6_DEFAULT" ]; then
    hint "$(text 78)"
    echo -e " 1. ${SERVER_IPV4_DEFAULT} (IPv4 默认)"
    echo -e " 2. ${SERVER_IPV6_DEFAULT} (IPv6)"
    echo -e " 3. 127.0.0.1 (本地监听)"
    reading "$(text 79)" choice
    case "$choice" in
      2) SERVER_IP="$SERVER_IPV6_DEFAULT" ;;
      3) SERVER_IP="127.0.0.1" ;;
      *) SERVER_IP="$SERVER_IPV4_DEFAULT" ;;
    esac
  elif [ -n "$SERVER_IPV4_DEFAULT" ] || [ -n "$SERVER_IPV6_DEFAULT" ]; then
    SERVER_IP="${SERVER_IPV4_DEFAULT}${SERVER_IPV6_DEFAULT}"
    hint "检测到 IP: $SERVER_IP"
    reading "$(text 79) (回车确认): " input
    [ -n "$input" ] && SERVER_IP="$input"
  else
    warning "自动获取失败"
    reading "请输入域名或公网 IP: " SERVER_IP
  fi

  # 端口选择
  while :; do
    reading "$(text 13)" PORT
    [ -z "$PORT" ] && PORT=$((RANDOM % 7169 + 1024)) && info "$(text 37) $PORT" && break
    ss -tln | grep -q ":$PORT " && warning "$(text 36)" || break
  done

  # 前缀选择
  reading "$(text 14)" PREFIX
  [ -z "$PREFIX" ] && PREFIX="api"
  PREFIX=$(echo "$PREFIX" | sed 's#^/##;s#/$##')

  hint "$(text 15)\n$(text 16)"
  reading "$(text 38)" TLS_MODE
  TLS_MODE=${TLS_MODE:-0}
  CMD="master://:${PORT}/${PREFIX}?tls=$TLS_MODE"
  [ "$TLS_MODE" = "2" ] && { reading "证书路径:" C; reading "密钥路径:" K; CMD="$CMD&crt=$C&key=$K"; }

  mkdir -p "$WORK_DIR" && mv "$TEMP_DIR/nodepass" "$WORK_DIR/" && mv "$TEMP_DIR/qrencode" "$WORK_DIR/"
  
  echo "SERVER_IP='$SERVER_IP'
CMD='$CMD'
PORT='$PORT'
PREFIX='$PREFIX'
TLS_MODE='$TLS_MODE'" > "$WORK_DIR/data"

  if [ "$SERVICE_MANAGE" = "systemctl" ]; then
    cat > /etc/systemd/system/nodepass.service <<EOF
[Unit]
Description=NodePass
After=network.target
[Service]
ExecStart=$WORK_DIR/nodepass "$CMD"
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now nodepass >/dev/null 2>&1
  fi

  echo -e "#!/bin/bash\nbash <(curl -sL https://raw.githubusercontent.com/Kook-9527/VPS_Plugin/main/nodepass/np.sh) \"\$@\"" > /usr/bin/np
  chmod +x /usr/bin/np
  ln -sf "$WORK_DIR/nodepass" /usr/bin/nodepass 2>/dev/null

  info "$(text 10)"
  echo "------------------------"
  get_api_url output
  start_nodepass
  get_api_key output
  get_uri output
  echo "------------------------"
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
  info " 当前版本: v1.14.3"
  info " 脚本版本: $SCRIPT_VERSION"

  if [ -f "$WORK_DIR/nodepass" ]; then
    pgrep -f nodepass >/dev/null && STATUS="$(text 34)" || STATUS="$(text 33)"
    OPTIONS=("1. $([ "$STATUS" = "$(text 34)" ] && echo "停止服务" || echo "启动服务")" "2. 卸载" "3. 查看信息" "0. 退出")
  else
    STATUS="$(text 32)"
    OPTIONS=("1. 安装" "0. 退出")
  fi

  info " NodePass: $STATUS"
  get_api_url output 2>/dev/null
  echo "------------------------"
  for i in "${!OPTIONS[@]}"; do hint "${OPTIONS[i]}"; done
  echo "------------------------"
  reading "$(text 38)" choice
  case "$choice" in
    1) if [ -f "$WORK_DIR/nodepass" ]; then pgrep -f nodepass >/dev/null && (systemctl stop nodepass 2>/dev/null; pkill -9 nodepass) || start_nodepass; else install; fi ;;
    2) systemctl stop nodepass 2>/dev/null; pkill -9 nodepass; rm -rf "$WORK_DIR" /usr/bin/np /usr/bin/nodepass /etc/systemd/system/nodepass.service; systemctl daemon-reload 2>/dev/null; info "$(text 11)" ;;
    3) echo "------------------------"; get_api_url output; get_api_key output; get_uri output; echo "------------------------" ;;
    0) exit ;;
    *) menu ;;
  esac
}

check_root; check_system; check_dependencies
case "$1" in -i) install ;; -u) menu ;; -o) menu ;; -s) get_api_url output; get_api_key output; get_uri output ;; *) menu ;; esac
