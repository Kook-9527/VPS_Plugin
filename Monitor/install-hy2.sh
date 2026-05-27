#!/usr/bin/env bash
# =============================================
# Hysteria 2 交互管理脚本
# - 自动安装依赖 + 一键部署/管理
# =============================================
set -euo pipefail

# ==================== 配置区 ====================
HY_PORT=22222
HY_HOP_START=60000
HY_HOP_END=65000
HY_DOMAIN="www.amd.com"
HY_SERVER_DIR="/etc/hysteria"
HY_CLIENT_DIR="/root/hysteria-client"
HY_CA_DIR="$HY_SERVER_DIR/ca"
HY_CERT="$HY_CA_DIR/server.crt"
HY_KEY="$HY_CA_DIR/server.key"
HY_SERVICE="hysteria-server"
SCRIPT_NAME=$(basename "$0")
# ================================================

# ---- 颜色 ----
if command -v tput &>/dev/null; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BLUE='\033[0;34m'; NC='\033[0m'
  BOLD='\033[1m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; NC=''; BOLD=''
fi

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
header(){ echo -e "\n${BOLD}$1${NC}"; }
sep()   { echo -e "======================================"; }

# ---- root 检测 ----
check_root() {
  if [[ $EUID -ne 0 ]]; then
    error "请以 root 用户运行"
    exit 1
  fi
}

# ---- 自动安装依赖 ----
install_deps() {
  local missing_deps=()
  
  for cmd in curl openssl iptables base64 tr head fold shuf; do
    command -v "$cmd" &>/dev/null || missing_deps+=("$cmd")
  done
  
  if [[ ${#missing_deps[@]} -eq 0 ]]; then
    info "所有依赖已满足"
    return 0
  fi
  
  echo -e "${YELLOW}[!] 缺失依赖: ${missing_deps[*]}${NC}"
  
  # 检测包管理器
  local pm=""
  local pm_install=""
  local pkg_map=()
  
  if command -v apt &>/dev/null; then
    pm="apt"; pm_install="apt install -y"
    pkg_map=( ["curl"]="curl" ["openssl"]="openssl" ["iptables"]="iptables" ["base64"]="coreutils" ["shuf"]="coreutils" ["fold"]="coreutils" )
  elif command -v yum &>/dev/null; then
    pm="yum"; pm_install="yum install -y"
    pkg_map=( ["curl"]="curl" ["openssl"]="openssl" ["iptables"]="iptables" ["base64"]="coreutils" ["shuf"]="coreutils" ["fold"]="coreutils" )
  elif command -v apk &>/dev/null; then
    pm="apk"; pm_install="apk add"
    pkg_map=( ["curl"]="curl" ["openssl"]="openssl" ["iptables"]="iptables" ["base64"]="coreutils" ["shuf"]="coreutils" ["fold"]="coreutils" )
  elif command -v opkg &>/dev/null; then
    pm="opkg"; pm_install="opkg install"
    pkg_map=( ["curl"]="curl" ["openssl"]="openssl" ["iptables"]="iptables" ["base64"]="coreutils" ["shuf"]="coreutils" ["fold"]="coreutils" )
  else
    warn "无法检测包管理器，请手动安装依赖: ${missing_deps[*]}"
    return 1
  fi
  
  local to_install=()
  for dep in "${missing_deps[@]}"; do
    local pkg="${pkg_map[$dep]:-$dep}"
    # 去重
    local skip=0
    for installed in "${to_install[@]}"; do [[ "$installed" == "$pkg" ]] && skip=1 && break; done
    [[ $skip -eq 0 ]] && to_install+=("$pkg")
  done
  
  echo -e "${YELLOW}[>] 正在安装: ${to_install[*]}${NC}"
  $pm_install "${to_install[@]}" > /dev/null 2>&1 && info "依赖安装完成" || warn "部分依赖安装可能失败"
}

# ---- 获取外网 IP ----
get_server_ip() {
  local ip=""
  ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
       curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
       curl -s --connect-timeout 5 https://httpbin.org/ip 2>/dev/null | grep -oP '"origin":\s*"\K[^"]+' || \
       ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
  echo "${ip:-$(hostname -I | awk '{print $1}')}"
}

# ---- 获取网卡接口 ----
get_interface() {
  ip route get 1 | awk '{print $5;exit}' 2>/dev/null || echo "eth0"
}

# ---- 生成密码 ----
gen_password() {
  local nums letters mixed
  nums=$(tr -dc '0-9' </dev/urandom | head -c5)
  letters=$(tr -dc 'A-Za-z' </dev/urandom | head -c15)
  mixed=$(echo "${nums}${letters}" | fold -w1)
  if command -v shuf &>/dev/null; then
    echo "$mixed" | shuf | tr -d '\n'
  else
    echo "$mixed" | sort -R | tr -d '\n'
  fi
}

# ---- 获取当前配置值 ----
get_config_val() {
  local key="$1"
  local file="$HY_SERVER_DIR/config.yaml"
  [[ ! -f "$file" ]] && echo "" && return
  case "$key" in
    port)
      grep -oP 'listen:\s*:\K\d+' "$file" 2>/dev/null || echo "$HY_PORT"
      ;;
    password)
      grep -oP 'password:\s*"\K[^"]+' "$file" 2>/dev/null || echo ""
      ;;
    hop_start)
      # 从 iptables 获取
      local iface
      iface=$(get_interface)
      iptables -t nat -L PREROUTING -n 2>/dev/null | grep -oP 'dports \K\d+' | head -1 || echo "$HY_HOP_START"
      ;;
    hop_end)
      local iface
      iface=$(get_interface)
      iptables -t nat -L PREROUTING -n 2>/dev/null | grep -oP 'dports \K\d+:\K\d+' | head -1 || echo "$HY_HOP_END"
      ;;
    domain)
      openssl x509 -noout -subject -in "$HY_CERT" 2>/dev/null | grep -oP 'CN\s*=\s*\K[^, ]+' || echo "$HY_DOMAIN"
      ;;
  esac
}

# ---- 安装/部署 Hysteria ----
install_hysteria() {
  header "🛠️ 安装 Hysteria 2"
  
  # 已安装检测
  if command -v hysteria &>/dev/null && [[ -f "$HY_SERVER_DIR/config.yaml" ]]; then
    echo -e "  ${YELLOW}Hysteria 已安装${NC}"
    read -r -p "  是否重新安装? [y/N] " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "  已取消"; return; }
  fi
  
  # 依赖
  install_deps
  
  # 安装 hysteria
  if ! command -v hysteria &>/dev/null; then
    echo -e "${YELLOW}[>] 下载 Hysteria 2...${NC}"
    bash <(curl -fsSL https://get.hy2.sh/) 2>&1 | grep -v 'tput' || true
    command -v hysteria &>/dev/null || { error "安装失败"; return 1; }
    info "Hysteria 安装完成"
  else
    info "Hysteria 已存在 ($(hysteria version 2>/dev/null | grep -i version | head -1))"
  fi
  
  # 交互配置
  echo ""
  echo -e "  ${CYAN}请配置以下参数（直接回车使用默认值）：${NC}"
  
  read -r -p "  监听端口 [$HY_PORT]: " input
  HY_PORT="${input:-$HY_PORT}"
  
  read -r -p "  端口跳跃起始 [$HY_HOP_START]: " input
  HY_HOP_START="${input:-$HY_HOP_START}"
  
  read -r -p "  端口跳跃结束 [$HY_HOP_END]: " input
  HY_HOP_END="${input:-$HY_HOP_END}"
  
  read -r -p "  伪装域名/SNI [$HY_DOMAIN]: " input
  HY_DOMAIN="${input:-$HY_DOMAIN}"
  
  # 自动生成或手动输入密码
  local pw
  pw=$(gen_password)
  read -r -p "  密码（回车自动生成: $pw）: " input
  HY_PASSWORD="${input:-$pw}"
  
  echo ""
  
  # 生成证书
  mkdir -p "$HY_CA_DIR"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 36500 -keyout "$HY_KEY" -out "$HY_CERT" \
    -subj "/CN=$HY_DOMAIN" 2>/dev/null
  CERT_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$HY_CERT" | cut -d= -f2)
  info "自签证书已生成 (CN=$HY_DOMAIN)"
  
  # 端口跳跃
  local iface
  iface=$(get_interface)
  iptables -t nat -D PREROUTING -i "$iface" -p udp --dport "$HY_HOP_START:$HY_HOP_END" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
  iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$HY_HOP_START:$HY_HOP_END" -j REDIRECT --to-ports "$HY_PORT" && info "端口跳跃规则已添加" || warn "iptables 规则失败"
  
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  if ! crontab -l 2>/dev/null | grep -q "iptables-restore.*rules.v4"; then
    (crontab -l 2>/dev/null; echo "@reboot iptables-restore < /etc/iptables/rules.v4 2>/dev/null") | crontab - 2>/dev/null || true
  fi
  
  # 生成服务端配置
  cat > "$HY_SERVER_DIR/config.yaml" << EOF
# Hysteria 2 服务端配置
listen: :$HY_PORT

tls:
  cert: $HY_CERT
  key: $HY_KEY

auth:
  type: password
  password: "$HY_PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: https://$HY_DOMAIN/
    rewriteHost: true

udp:
  hopInterval: 30s
EOF
  chmod 600 "$HY_SERVER_DIR/config.yaml"
  info "服务端配置已生成"
  
  # systemd 服务
  local svc="/etc/systemd/system/$HY_SERVICE.service"
  if [[ -f "$svc" ]]; then
    sed -i 's/^User=.*/User=root/' "$svc"
    sed -i 's|^WorkingDirectory=.*|WorkingDirectory='\"$HY_SERVER_DIR\"'|' "$svc"
    grep -q 'CAP_NET_ADMIN' "$svc" 2>/dev/null || sed -i '/CapabilityBoundingSet/s/$/ CAP_NET_ADMIN/' "$svc"
    grep -q 'CAP_NET_ADMIN' "$svc" 2>/dev/null || sed -i '/AmbientCapabilities/s/$/ CAP_NET_ADMIN/' "$svc"
    systemctl daemon-reload
  fi
  
  # 启动
  systemctl enable "$HY_SERVICE" 2>/dev/null || true
  systemctl restart "$HY_SERVICE" 2>&1 | tail -1 || true
  sleep 2
  
  if systemctl is-active --quiet "$HY_SERVICE" 2>/dev/null; then
    info "✅ Hysteria 服务运行中"
  else
    warn "服务启动异常，日志: journalctl -u $HY_SERVICE --no-pager -n 20"
  fi
  
  # 生成客户端配置
  local server_ip
  server_ip=$(get_server_ip)
  mkdir -p "$HY_CLIENT_DIR"
  cp "$HY_CERT" "$HY_CLIENT_DIR/ca.crt"
  
  cat > "$HY_CLIENT_DIR/client.yaml" << EOF
# Hysteria 2 客户端配置
server: ${server_ip}:${HY_PORT},${HY_HOP_START}-${HY_HOP_END}

auth: "${HY_PASSWORD}"

bandwidth:
  up: 50 mbps
  down: 200 mbps

tls:
  insecure: true
  sni: ${HY_DOMAIN}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080

transport:
  udp:
    hopInterval: 30s
EOF
  
  local link
  link="hy2://${HY_PASSWORD}@${server_ip}:${HY_PORT}?insecure=1&sni=${HY_DOMAIN}&mport=${HY_PORT},${HY_HOP_START}-${HY_HOP_END}&hopinterval=30#Hysteria2-${server_ip}"
  echo "$link" > "$HY_CLIENT_DIR/link.txt"
  
  info "客户端配置: $HY_CLIENT_DIR/client.yaml"
  
  # 完成信息
  sep
  echo -e " ${GREEN}✅ Hysteria 2 安装完成！${NC}"
  show_node_info
}

# ---- 修改配置 ----
modify_config() {
  header "⚙️ 修改配置"
  
  [[ ! -f "$HY_SERVER_DIR/config.yaml" ]] && { error "Hysteria 未安装，请先执行选项 1"; return; }
  
  local cur_port cur_pw cur_domain cur_hop_start cur_hop_end
  cur_port=$(get_config_val "port")
  cur_pw=$(get_config_val "password")
  cur_domain=$(get_config_val "domain")
  cur_hop_start=$(get_config_val "hop_start")
  cur_hop_end=$(get_config_val "hop_end")
  
  echo -e "  ${CYAN}请选择要修改的项目（直接回车跳过）：${NC}"
  echo ""
  
  read -r -p "  监听端口 [当前: $cur_port]: " input
  local new_port="${input:-$cur_port}"
  
  read -r -p "  端口跳跃起始 [当前: $cur_hop_start]: " input
  local new_hop_start="${input:-$cur_hop_start}"
  
  read -r -p "  端口跳跃结束 [当前: $cur_hop_end]: " input
  local new_hop_end="${input:-$cur_hop_end}"
  
  read -r -p "  伪装域名/SNI [当前: $cur_domain]: " input
  local new_domain="${input:-$cur_domain}"
  
  # 密码：回车保留，输入新密码，输入 'random' 自动生成
  echo -e "  ${YELLOW}密码: 直接回车=保留, 输入=新密码, 输入 random=随机生成${NC}"
  read -r -p "  [当前: ${cur_pw:0:4}****]: " input
  local new_pw="$cur_pw"
  if [[ "$input" == "random" ]]; then
    new_pw=$(gen_password)
    info "新密码已生成: $new_pw"
  elif [[ -n "$input" ]]; then
    new_pw="$input"
  fi
  
  # 检查是否有实际改动
  if [[ "$cur_port" == "$new_port" && "$cur_pw" == "$new_pw" && "$cur_domain" == "$new_domain" && "$cur_hop_start" == "$new_hop_start" && "$cur_hop_end" == "$new_hop_end" ]]; then
    echo -e "  ${YELLOW}没有修改任何配置${NC}"
    return
  fi
  
  echo ""
  echo -e "  ${YELLOW}正在应用修改...${NC}"
  
  # 端口跳跃
  local iface
  iface=$(get_interface)
  if [[ "$cur_hop_start" != "$new_hop_start" || "$cur_hop_end" != "$new_hop_end" ]]; then
    # 删除旧规则
    iptables -t nat -D PREROUTING -i "$iface" -p udp --dport "$cur_hop_start:$cur_hop_end" -j REDIRECT --to-ports "$cur_port" 2>/dev/null || true
    # 添加新规则
    iptables -t nat -A PREROUTING -i "$iface" -p udp --dport "$new_hop_start:$new_hop_end" -j REDIRECT --to-ports "$new_port" && \
      info "端口跳跃规则已更新 ($new_hop_start-$new_hop_end → :$new_port)" || warn "iptables 规则更新失败"
    # 持久化
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
  
  # 证书（域名改了才重签）
  if [[ "$cur_domain" != "$new_domain" ]]; then
    rm -f "$HY_CERT" "$HY_KEY"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 36500 -keyout "$HY_KEY" -out "$HY_CERT" \
      -subj "/CN=$new_domain" 2>/dev/null
    cp "$HY_CERT" "$HY_CLIENT_DIR/ca.crt" 2>/dev/null || true
    info "证书已重新生成 (CN=$new_domain)"
  fi
  
  # 更新服务端配置
  cat > "$HY_SERVER_DIR/config.yaml" << EOF
# Hysteria 2 服务端配置
listen: :$new_port

tls:
  cert: $HY_CERT
  key: $HY_KEY

auth:
  type: password
  password: "$new_pw"

masquerade:
  type: proxy
  proxy:
    url: https://$new_domain/
    rewriteHost: true

udp:
  hopInterval: 30s
EOF
  chmod 600 "$HY_SERVER_DIR/config.yaml"
  
  # 更新客户端配置
  local server_ip
  server_ip=$(get_server_ip)
  mkdir -p "$HY_CLIENT_DIR"
  
  cat > "$HY_CLIENT_DIR/client.yaml" << EOF
# Hysteria 2 客户端配置
server: ${server_ip}:${new_port},${new_hop_start}-${new_hop_end}

auth: "${new_pw}"

bandwidth:
  up: 50 mbps
  down: 200 mbps

tls:
  insecure: true
  sni: ${new_domain}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080

transport:
  udp:
    hopInterval: 30s
EOF
  
  local link
  link="hy2://${new_pw}@${server_ip}:${new_port}?insecure=1&sni=${new_domain}&mport=${new_port},${new_hop_start}-${new_hop_end}&hopinterval=30#Hysteria2-${server_ip}"
  echo "$link" > "$HY_CLIENT_DIR/link.txt"
  
  # 重启服务
  systemctl restart "$HY_SERVICE" 2>&1 | tail -1 || true
  sleep 2
  
  if systemctl is-active --quiet "$HY_SERVICE" 2>/dev/null; then
    info "✅ 服务已重启，配置生效"
  else
    warn "服务重启异常"
  fi
  
  sep
  echo -e " ${GREEN}✅ 配置已更新！${NC}"
}

# ---- 查看节点信息 ----
show_node_info() {
  header "📋 节点信息"
  
  [[ ! -f "$HY_SERVER_DIR/config.yaml" ]] && { error "Hysteria 未安装"; return; }
  
  local port password domain hop_start hop_end server_ip cert_fp
  port=$(get_config_val "port")
  password=$(get_config_val "password")
  domain=$(get_config_val "domain")
  hop_start=$(get_config_val "hop_start")
  hop_end=$(get_config_val "hop_end")
  server_ip=$(get_server_ip)
  cert_fp=$(openssl x509 -noout -fingerprint -sha256 -in "$HY_CERT" 2>/dev/null | cut -d= -f2)
  
  local service_status="未安装"
  if systemctl is-active --quiet "$HY_SERVICE" 2>/dev/null; then
    service_status="${GREEN}● 运行中${NC}"
  elif [[ -f "$HY_SERVER_DIR/config.yaml" ]]; then
    service_status="${RED}● 已停止${NC}"
  fi
  
  local link
  link="hy2://${password}@${server_ip}:${port}?insecure=1&sni=${domain}&mport=${port},${hop_start}-${hop_end}&hopinterval=30#Hysteria2-${server_ip}"
  
  echo -e "  ${BOLD}服务状态:${NC}   ${service_status}"
  sep
  echo -e "  ${BOLD}服务器地址:${NC}  $server_ip"
  echo -e "  ${BOLD}主端口:${NC}      $port"
  echo -e "  ${BOLD}端口跳跃:${NC}    $hop_start - $hop_end"
  echo -e "  ${BOLD}密码:${NC}        $password"
  echo -e "  ${BOLD}SNI/域名:${NC}    $domain"
  echo -e "  ${BOLD}证书指纹:${NC}    ${cert_fp:-N/A}"
  sep
  echo -e "  ${BOLD}分享链接:${NC}"
  echo ""
  echo -e "  ${CYAN}$link${NC}"
  echo ""
  
  # 如果客户端配置文件存在，也显示
  if [[ -f "$HY_CLIENT_DIR/client.yaml" ]]; then
    echo -e "  ${BOLD}客户端配置文件:${NC} $HY_CLIENT_DIR/client.yaml"
  fi
}

# ---- 更新 Hysteria ----
update_hysteria() {
  header "🔄 更新 Hysteria 2"
  
  [[ ! -f "$HY_SERVER_DIR/config.yaml" ]] && { error "Hysteria 未安装，请先执行选项 1"; return; }
  
  echo "======================================"
  echo " 1) 手动更新"
  echo " 2) 自动更新（每天 4:00）"
  echo " 0) 返回主菜单"
  echo "======================================"
  read -r -p " 请输入选项 [0-2]: " sub_choice
  
  case "$sub_choice" in
    1)
      echo ""
      echo -e "  ${YELLOW}[>] 正在更新 Hysteria...${NC}"
      bash <(curl -fsSL https://get.hy2.sh/) 2>&1 | grep -v 'tput' || true
      
      if command -v hysteria &>/dev/null; then
        info "Hysteria 更新完成 ($(hysteria version 2>/dev/null | grep -i version | head -1))"
      else
        error "更新失败"
      fi
      ;;
    2)
      echo ""
      # 设置自动更新 cron
      local cron_job="0 4 * * * /bin/bash -c 'bash <(curl -fsSL https://get.hy2.sh/)'"
      
      if crontab -l 2>/dev/null | grep -q "get.hy2.sh"; then
        info "自动更新已设置（每天 4:00）"
        echo -e "  ${YELLOW}当前规则:${NC}"
        crontab -l 2>/dev/null | grep "get.hy2.sh"
      else
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        info "✅ 自动更新已启用，每天 4:00 自动更新 Hysteria"
        echo ""
        echo -e "  ${YELLOW}如需取消自动更新，请执行:${NC}"
        echo -e "  crontab -l | grep -v 'get.hy2.sh' | crontab -"
      fi
      ;;
    0)
      return
      ;;
    *)
      warn "无效选项"
      ;;
  esac
}

# ---- 卸载 ----
uninstall_hysteria() {
  header "🗑️ 卸载 Hysteria 2"
  
  [[ ! -f "$HY_SERVER_DIR/config.yaml" ]] && { error "Hysteria 未安装"; return; }
  
  read -r -p "  确认卸载 Hysteria 2? [y/N] " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "  已取消"; return; }
  
  echo -e "${YELLOW}[>] 停止服务...${NC}"
  systemctl stop "$HY_SERVICE" 2>/dev/null || true
  systemctl disable "$HY_SERVICE" 2>/dev/null || true
  
  echo -e "${YELLOW}[>] 删除文件...${NC}"
  rm -f /usr/local/bin/hysteria
  rm -rf "$HY_SERVER_DIR"
  rm -rf "$HY_CLIENT_DIR"
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /etc/systemd/system/hysteria-server@.service
  systemctl daemon-reload
  
  echo -e "${YELLOW}[>] 清理 iptables 规则...${NC}"
  local iface
  iface=$(get_interface)
  iptables -t nat -D PREROUTING -i "$iface" -p udp --dport "$HY_HOP_START:$HY_HOP_END" -j REDIRECT --to-ports "$HY_PORT" 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  
  echo -e "${YELLOW}[>] 清理 crontab...${NC}"
  crontab -l 2>/dev/null | grep -v "iptables-restore.*rules.v4" | crontab - 2>/dev/null || true
  
  info "✅ Hysteria 2 已完全卸载"
}

# ==================== 主菜单 ====================
show_menu() {
  # 检查安装状态
  local installed=""
  local version_info=""
  if command -v hysteria &>/dev/null && [[ -f "$HY_SERVER_DIR/config.yaml" ]]; then
    if systemctl is-active --quiet "$HY_SERVICE" 2>/dev/null; then
      installed="${GREEN}已安装 ✓${NC}"
    else
      installed="${RED}已停止${NC}"
    fi
    version_info=$(hysteria version 2>/dev/null | grep -oP 'Version:\s*\K\S+' | head -1 || echo "")
  else
    installed="${YELLOW}未安装${NC}"
  fi

  # 获取当前端口、更新状态等信息
  local cur_port cur_hop_start cur_hop_end
  cur_port=$(get_config_val "port")
  cur_hop_start=$(get_config_val "hop_start")
  cur_hop_end=$(get_config_val "hop_end")
  [[ -z "$cur_port" ]] && cur_port="$HY_PORT"
  [[ -z "$cur_hop_start" ]] && cur_hop_start="$HY_HOP_START"
  [[ -z "$cur_hop_end" ]] && cur_hop_end="$HY_HOP_END"
  
  local auto_update_status="${YELLOW}未开启${NC}"
  if crontab -l 2>/dev/null | grep -q "get.hy2.sh"; then
    auto_update_status="${GREEN}每天 4:00${NC}"
  fi
  
  echo ""
  echo "======================================"
  echo " Hysteria2 管理脚本 丨 by：Kook9527"
  echo "======================================"
  echo -e " 服务状态：$installed 丨版本：${version_info:-N/A}"
  echo -e " 监听端口：$cur_port    丨端口跳跃：$cur_hop_start-$cur_hop_end"
  echo -e " 快捷命令：hy2      丨自动更新：$auto_update_status"
  echo "======================================"
  echo " 1) 安装/重新安装"
  echo " 2) 修改配置"
  echo " 3) 查看节点信息"
  echo " 4) 更新"
  echo " 5) 卸载"
  echo " 0) 退出"
  echo "======================================"
  read -r -p " 请输入选项 [0-5]: " choice || true
  
  case "$choice" in
    1) install_hysteria ;;
    2) modify_config ;;
    3) show_node_info ;;
    4) update_hysteria ;;
    5) uninstall_hysteria ;;
    0) echo -e "  ${GREEN}再见！${NC}"; exit 0 ;;
    *) warn "无效选项" ;;
  esac
  
  echo ""
  read -r -p "  按回车返回菜单..." || true
  show_menu
}

# ==================== 设置 hy2 快捷命令 ====================
setup_shortcut() {
  local script_path
  script_path="$(readlink -f "$0")"
  
  if [[ ! -L /usr/local/bin/hy2 ]] || [[ "$(readlink /usr/local/bin/hy2)" != "$script_path" ]]; then
    ln -sf "$script_path" /usr/local/bin/hy2
    chmod +x "$script_path"
    info "快捷命令已设置：输入 hy2 即可进入脚本"
  fi
}

# ==================== 启动 ====================
check_root
setup_shortcut
show_menu
