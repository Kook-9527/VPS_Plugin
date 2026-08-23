#!/bin/sh
# Alpine Hysteria 2 交互管理脚本
# 安装原理参考 zrlhk/alpine-hysteria2，界面参考 Kook-9527/VPS_Plugin。
set -u

DEFAULT_PORT=40000
DEFAULT_DOMAIN="www.amd.com"
PASSWORD_LENGTH=20
HY_DIR="/etc/hysteria"
CLIENT_DIR="/root/hysteria-client"
CONFIG="$HY_DIR/config.yaml"
CERT="$HY_DIR/server.crt"
KEY="$HY_DIR/server.key"
META="$HY_DIR/manager.conf"
SERVICE="hysteria"
MANAGED_SCRIPT="/usr/local/sbin/Alpine_install-hy2.sh"
RELEASE_API="https://api.github.com/repos/apernet/hysteria/releases/latest"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

say()   { printf '%b\n' "$*"; }
info()  { say "${GREEN}[✓]${NC} $*"; }
warn()  { say "${YELLOW}[!]${NC} $*"; }
error() { say "${RED}[✗]${NC} $*" >&2; }
header(){ say "\n${BOLD}$*${NC}"; }
sep()   { say "=========================================="; }
pause() { printf '  按回车返回菜单...'; IFS= read -r _ || true; }

check_environment() {
  [ "${HY2_TEST_MODE:-0}" = "1" ] && return 0
  [ "$(id -u)" -eq 0 ] || { error "请以 root 用户运行"; exit 1; }
  [ -f /etc/alpine-release ] || { error "本脚本仅支持 Alpine Linux"; exit 1; }
  command -v rc-service >/dev/null 2>&1 || { error "未找到 OpenRC"; exit 1; }
}

install_deps() {
  info "检查 Alpine 依赖"
  apk add --no-cache curl openssl ca-certificates openrc jq >/dev/null || {
    error "依赖安装失败"
    return 1
  }
}

meta_get() {
  [ -f "$META" ] || return 0
  sed -n "s/^$1=//p" "$META" | tail -n 1
}

config_port() {
  if [ -f "$CONFIG" ]; then
    sed -n 's/^[[:space:]]*listen:[[:space:]]*:\([0-9][0-9]*\).*/\1/p' "$CONFIG" | head -n 1
  else
    printf '%s\n' "$DEFAULT_PORT"
  fi
}

config_password() {
  [ -f "$CONFIG" ] || return 0
  sed -n 's/^[[:space:]]*password:[[:space:]]*"\([A-Za-z0-9]*\)".*/\1/p' "$CONFIG" | head -n 1
}

config_domain() {
  value=$(meta_get DOMAIN)
  if [ -n "$value" ]; then printf '%s\n' "$value"; return; fi
  if [ -f "$CERT" ]; then
    openssl x509 -in "$CERT" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^, ]*\).*/\1/p'
  else
    printf '%s\n' "$DEFAULT_DOMAIN"
  fi
}

server_address() {
  value=$(meta_get SERVER_ADDR)
  [ -n "$value" ] && { printf '%s\n' "$value"; return; }
  if [ -f "$HY_DIR/share-link.txt" ]; then
    value=$(sed -n 's|^[^:]*://[^@]*@\([^:/?]*\).*|\1|p' "$HY_DIR/share-link.txt" | head -n 1)
    [ -n "$value" ] && { printf '%s\n' "$value"; return; }
  fi
  value=$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
  printf '%s\n' "${value:-服务器IP}"
}

detect_server_ip() {
  value=$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
  if [ -n "$value" ]; then printf '%s\n' "$value"; else server_address; fi
}

installed_version() {
  if command -v hysteria >/dev/null 2>&1; then
    hysteria version 2>/dev/null | sed -n 's/^Version:[[:space:]]*//p' | head -n 1
  fi
}

service_running() {
  [ "${HY2_TEST_MODE:-0}" = "1" ] && return 1
  rc-service "$SERVICE" status >/dev/null 2>&1
}

gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$PASSWORD_LENGTH"
  printf '\n'
}

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_domain() {
  case "$1" in ''|*[!A-Za-z0-9.-]*|.*|*..*|*.) return 1;; *) return 0;; esac
}

valid_address() {
  case "$1" in ''|*[!A-Za-z0-9.:-]*) return 1;; *) return 0;; esac
}

valid_password() {
  [ ${#1} -ge 8 ] && [ ${#1} -le 64 ] || return 1
  case "$1" in *[!A-Za-z0-9]*) return 1;; *) return 0;; esac
}

prompt_value() {
  label="$1"; default="$2"
  printf '  %s [%s]: ' "$label" "$default" >&2
  IFS= read -r value || true
  printf '%s\n' "${value:-$default}"
}

arch_name() {
  case "$(uname -m)" in
    x86_64) printf 'amd64\n';;
    aarch64) printf 'arm64\n';;
    armv7l|armv7) printf 'armv7\n';;
    i?86) printf '386\n';;
    *) error "不支持的架构: $(uname -m)"; return 1;;
  esac
}

download_candidate() {
  arch=$(arch_name) || return 1
  json=$(mktemp) || return 1
  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 "$RELEASE_API" -o "$json"; then
    rm -f "$json"; error "读取官方版本信息失败"; return 1
  fi
  asset="hysteria-linux-$arch"
  DOWNLOAD_TAG=$(jq -r '.tag_name // empty' "$json")
  url=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' "$json" | head -n 1)
  digest=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | (.digest // empty)' "$json" | head -n 1)
  rm -f "$json"
  case "$digest" in sha256:*) sha=${digest#sha256:};; *) error "官方发布缺少 digest/SHA256"; return 1;; esac
  if [ -z "$DOWNLOAD_TAG" ] || [ -z "$url" ] || [ ${#sha} -ne 64 ]; then
    error "官方版本信息解析失败"; return 1
  fi
  DOWNLOAD_FILE=$(mktemp) || return 1
  if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$DOWNLOAD_FILE"; then
    rm -f "$DOWNLOAD_FILE"; error "Hysteria 下载失败"; return 1
  fi
  if ! printf '%s  %s\n' "$sha" "$DOWNLOAD_FILE" | sha256sum -c - >/dev/null; then
    rm -f "$DOWNLOAD_FILE"; error "Hysteria SHA256 校验失败"; return 1
  fi
  chmod 755 "$DOWNLOAD_FILE"
  if ! "$DOWNLOAD_FILE" version >/dev/null 2>&1; then
    rm -f "$DOWNLOAD_FILE"; error "下载的二进制无法执行"; return 1
  fi
  info "官方 $DOWNLOAD_TAG 下载完成（SHA256 已校验）"
}

cert_fingerprint() {
  openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

backup_current() {
  BACKUP_DIR="/root/hy2-backups/$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  [ -d "$HY_DIR" ] && cp -a "$HY_DIR" "$BACKUP_DIR/hysteria"
  [ -d "$CLIENT_DIR" ] && cp -a "$CLIENT_DIR" "$BACKUP_DIR/hysteria-client"
  [ -f /etc/init.d/hysteria ] && cp -p /etc/init.d/hysteria "$BACKUP_DIR/hysteria.init"
  [ -f /usr/local/bin/hysteria ] && cp -p /usr/local/bin/hysteria "$BACKUP_DIR/hysteria.bin"
  info "已备份当前节点: $BACKUP_DIR"
}

restore_backup() {
  rc-service hysteria stop >/dev/null 2>&1 || true
  rm -rf "$HY_DIR" "$CLIENT_DIR"
  rm -f /etc/init.d/hysteria /usr/local/bin/hysteria
  [ -d "$BACKUP_DIR/hysteria" ] && cp -a "$BACKUP_DIR/hysteria" "$HY_DIR"
  [ -d "$BACKUP_DIR/hysteria-client" ] && cp -a "$BACKUP_DIR/hysteria-client" "$CLIENT_DIR"
  [ -f "$BACKUP_DIR/hysteria.init" ] && cp -p "$BACKUP_DIR/hysteria.init" /etc/init.d/hysteria
  [ -f "$BACKUP_DIR/hysteria.bin" ] && cp -p "$BACKUP_DIR/hysteria.bin" /usr/local/bin/hysteria
  rc-service hysteria start >/dev/null 2>&1 || true
}

write_openrc_service() {
  cat > /etc/init.d/hysteria.tmp <<'EOF'
#!/sbin/openrc-run
name="hysteria"
description="Hysteria 2 server"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"
output_log="/var/log/hysteria/server.log"
error_log="/var/log/hysteria/server.log"
depend() {
  need net
  after firewall
}
EOF
  install -m 755 /etc/init.d/hysteria.tmp /etc/init.d/hysteria
  rm -f /etc/init.d/hysteria.tmp
}

write_node_files() {
  port="$1"; domain="$2"; password="$3"; address="$4"; renew_cert="$5"
  mkdir -p "$HY_DIR" "$CLIENT_DIR" /var/log/hysteria
  chmod 700 "$HY_DIR" "$CLIENT_DIR"
  if [ "$renew_cert" = "1" ] || [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 36500 -keyout "$KEY.tmp" -out "$CERT.tmp" -subj "/CN=$domain" >/dev/null 2>&1; then
      error "证书生成失败"; return 1
    fi
    mv "$KEY.tmp" "$KEY"; mv "$CERT.tmp" "$CERT"
  fi
  chmod 600 "$KEY"; chmod 644 "$CERT"
  fp=$(cert_fingerprint) || return 1

  cat > "$CONFIG.tmp" <<EOF
listen: :$port

tls:
  cert: $CERT
  key: $KEY

auth:
  type: password
  password: "$password"

masquerade:
  type: proxy
  proxy:
    url: https://$domain/
    rewriteHost: true
EOF
  install -m 600 "$CONFIG.tmp" "$CONFIG"; rm -f "$CONFIG.tmp"

  cat > "$META.tmp" <<EOF
PORT=$port
DOMAIN=$domain
SERVER_ADDR=$address
EOF
  install -m 600 "$META.tmp" "$META"; rm -f "$META.tmp"

  cat > "$CLIENT_DIR/client.yaml.tmp" <<EOF
server: $address:$port
auth: "$password"
tls:
  insecure: true
  sni: $domain
  pinSHA256: $fp
socks5:
  listen: 127.0.0.1:1080
EOF
  install -m 600 "$CLIENT_DIR/client.yaml.tmp" "$CLIENT_DIR/client.yaml"
  rm -f "$CLIENT_DIR/client.yaml.tmp"
  cp "$CERT" "$CLIENT_DIR/ca.crt"; chmod 644 "$CLIENT_DIR/ca.crt"

  link="hysteria2://$password@$address:$port/?insecure=1&sni=$domain&pinSHA256=$fp#Hysteria2-$address"
  printf '%s\n' "$link" > "$CLIENT_DIR/link.txt"
  printf '%s\n' "$link" > "$HY_DIR/share-link.txt"
  printf 'Hysteria2-%s = hysteria2, %s, %s, password=%s, skip-cert-verify=true, sni=%s, server-cert-fingerprint-sha256=%s, udp-relay=true\n' \
    "$address" "$address" "$port" "$password" "$domain" "$fp" > "$CLIENT_DIR/loon.conf"
  chmod 600 "$CLIENT_DIR/link.txt" "$HY_DIR/share-link.txt" "$CLIENT_DIR/loon.conf"
  write_openrc_service
}

apply_install() {
  port="$1"; domain="$2"; password="$3"; address="$4"; renew_cert="$5"
  backup_current
  rc-service hysteria stop >/dev/null 2>&1 || true
  install -m 755 "$DOWNLOAD_FILE" /usr/local/bin/hysteria
  rm -f "$DOWNLOAD_FILE"
  if ! write_node_files "$port" "$domain" "$password" "$address" "$renew_cert"; then
    error "配置写入失败，正在恢复"; restore_backup; return 1
  fi
  rc-update add hysteria default >/dev/null 2>&1 || true
  if ! rc-service hysteria start >/dev/null 2>&1; then
    error "服务启动失败，正在恢复"; restore_backup; return 1
  fi
  sleep 2
  if ! rc-service hysteria status >/dev/null 2>&1; then
    error "服务状态异常，正在恢复"; restore_backup; return 1
  fi
  info "Hysteria 服务运行中"
}

confirm_server_address() {
  detected="$1"
  printf '  服务器地址 [%s]（回车确认或输入IP/DDNS）：' "$detected"
  IFS= read -r input || true
  SELECTED_ADDRESS="${input:-$detected}"
  valid_address "$SELECTED_ADDRESS" || { error "节点地址格式无效"; return 1; }
}

install_hysteria() {
  header "🛠️ 安装 Hysteria 2"
  if [ -f "$CONFIG" ]; then
    printf '  Hysteria 已安装，是否重新安装? [y/N] '
    IFS= read -r confirm || true
    case "$confirm" in y|Y) :;; *) say "  已取消"; return;; esac
  fi
  install_deps || return 1
  old_port=$(config_port); old_domain=$(config_domain); detected_address=$(detect_server_ip)
  confirm_server_address "$detected_address" || return 1
  address="$SELECTED_ADDRESS"
  port=$(prompt_value "监听端口" "${old_port:-$DEFAULT_PORT}")
  valid_port "$port" || { error "端口必须是 1-65535"; return 1; }
  random_password=$(gen_password)
  password=$(prompt_value "密码（回车随机生成 20 位）" "$random_password")
  valid_password "$password" || { error "密码需为 8-64 位大小写字母或数字"; return 1; }
  domain=$(prompt_value "伪装域名/SNI" "${old_domain:-$DEFAULT_DOMAIN}")
  valid_domain "$domain" || { error "伪装域名格式无效"; return 1; }
  download_candidate || return 1
  apply_install "$port" "$domain" "$password" "$address" 1 || return 1
  sep; info "Hysteria 2 安装完成"; show_node_info
}

modify_config() {
  header "⚙️ 修改配置"
  [ -f "$CONFIG" ] || { error "Hysteria 未安装，请先执行选项 1"; return; }
  old_port=$(config_port); old_domain=$(config_domain); old_address=$(server_address); old_password=$(config_password)
  port=$(prompt_value "监听端口" "$old_port")
  valid_port "$port" || { error "端口无效"; return 1; }
  domain=$(prompt_value "伪装域名/SNI" "$old_domain")
  valid_domain "$domain" || { error "伪装域名格式无效"; return 1; }
  address=$(prompt_value "节点地址（IP或域名）" "$old_address")
  valid_address "$address" || { error "节点地址格式无效"; return 1; }
  say "  密码：回车保留，输入 random 生成 20 位新密码，或输入自定义密码"
  printf '  [当前: %.4s****]: ' "$old_password"; IFS= read -r input || true
  case "$input" in '') password=$old_password;; random) password=$(gen_password);; *) password=$input;; esac
  valid_password "$password" || { error "密码需为 8-64 位大小写字母或数字"; return 1; }
  DOWNLOAD_FILE=$(mktemp); cp -p /usr/local/bin/hysteria "$DOWNLOAD_FILE"; chmod 755 "$DOWNLOAD_FILE"
  renew=0; [ "$domain" = "$old_domain" ] || renew=1
  apply_install "$port" "$domain" "$password" "$address" "$renew" || return 1
  info "配置已更新"
  show_node_info
}

show_node_info() {
  header "📋 节点信息"
  [ -f "$CONFIG" ] || { error "Hysteria 未安装"; return; }
  port=$(config_port); domain=$(config_domain); address=$(server_address); password=$(config_password)
  version=$(installed_version); fp=$(cert_fingerprint)
  if service_running; then status="${GREEN}● 运行中${NC}"; else status="${RED}● 已停止${NC}"; fi
  say "  ${BOLD}服务状态:${NC}   $status"
  sep
  say "  ${BOLD}服务器地址:${NC} $address"
  say "  ${BOLD}监听端口:${NC}   $port/UDP"
  say "  ${BOLD}版本:${NC}       ${version:-N/A}"
  say "  ${BOLD}密码:${NC}       $password"
  say "  ${BOLD}SNI/域名:${NC}   $domain"
  say "  ${BOLD}证书指纹:${NC}   $fp"
  sep
  say "  ${BOLD}通用分享链接:${NC}"
  say "  ${CYAN}$(cat "$CLIENT_DIR/link.txt")${NC}"
  say ""
  say "  ${BOLD}Loon 配置:${NC}"
  say "  ${CYAN}$(cat "$CLIENT_DIR/loon.conf")${NC}"
}

update_hysteria() {
  header "🔄 更新 Hysteria 2"
  [ -f "$CONFIG" ] || { error "Hysteria 未安装"; return; }
  install_deps || return 1
  download_candidate || return 1
  BACKUP_DIR="/root/hy2-backups/$(date +%Y%m%d_%H%M%S)-update"
  mkdir -p "$BACKUP_DIR"; cp -p /usr/local/bin/hysteria "$BACKUP_DIR/hysteria.bin"
  rc-service hysteria stop >/dev/null 2>&1 || true
  install -m 755 "$DOWNLOAD_FILE" /usr/local/bin/hysteria; rm -f "$DOWNLOAD_FILE"
  if ! rc-service hysteria start >/dev/null 2>&1; then
    cp -p "$BACKUP_DIR/hysteria.bin" /usr/local/bin/hysteria
    rc-service hysteria start >/dev/null 2>&1 || true
    error "更新失败，已恢复原版本"; return 1
  fi
  sleep 2
  service_running || { error "更新后服务异常"; return 1; }
  info "更新完成，当前版本: $(installed_version)"
}

uninstall_hysteria() {
  header "🗑️ 卸载 Hysteria 2"
  [ -f "$CONFIG" ] || { error "Hysteria 未安装"; return; }
  printf '  确认卸载 Hysteria 2? [y/N] '; IFS= read -r confirm || true
  case "$confirm" in y|Y) :;; *) say "  已取消"; return;; esac
  backup_current
  rc-service hysteria stop >/dev/null 2>&1 || true
  rc-update del hysteria default >/dev/null 2>&1 || true
  rm -f /etc/init.d/hysteria /usr/local/bin/hysteria
  rm -rf "$HY_DIR" "$CLIENT_DIR"
  info "Hysteria 2 已卸载；管理命令 hy2 已保留，可随时重新安装"
}

render_menu() {
  port="N/A"; version="N/A"; state="${YELLOW}未安装${NC}  "
  if [ "${HY2_TEST_MODE:-0}" != "1" ] && [ -f "$CONFIG" ]; then
    port=$(config_port); version=$(installed_version)
    if service_running; then state="${GREEN}已安装 ✓${NC}"; else state="${RED}已停止${NC}  "; fi
  fi
  port_field=$(printf '%-8s' "$port")
  say ""; sep
  say " Hysteria2 Alpine 管理脚本 丨 by：Kook9527"
  sep
  say " 服务状态：${state}丨版本：${version:-N/A}"
  say " 监听端口：${port_field}丨快捷命令：hy2"
  sep
  say " 1) 安装/重新安装"
  say " 2) 修改配置"
  say " 3) 查看节点信息"
  say " 4) 更新"
  say " 5) 卸载"
  say " 0) 退出"
  sep
}

setup_shortcut() {
  [ "${HY2_TEST_MODE:-0}" = "1" ] && return
  src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
  mkdir -p /usr/local/sbin
  [ "$src" = "$MANAGED_SCRIPT" ] || install -m 755 "$src" "$MANAGED_SCRIPT"
  ln -sf "$MANAGED_SCRIPT" /usr/local/bin/hy2
}

main_menu() {
  while :; do
    render_menu
    printf ' 请输入选项 [0-5]: '; IFS= read -r choice || choice=0
    case "$choice" in
      1) install_hysteria;; 2) modify_config;; 3) show_node_info;;
      4) update_hysteria;; 5) uninstall_hysteria;;
      0) info "再见！"; exit 0;; *) warn "无效选项";;
    esac
    say ""; pause
  done
}

case "${1:-}" in
  --render-menu) render_menu; exit 0;;
  --defaults) printf 'PORT=%s\nDOMAIN=%s\nPASSWORD_LENGTH=%s\n' "$DEFAULT_PORT" "$DEFAULT_DOMAIN" "$PASSWORD_LENGTH"; exit 0;;
  --help) say "用法: $0 [--render-menu|--defaults]"; exit 0;;
esac

check_environment
setup_shortcut
main_menu
