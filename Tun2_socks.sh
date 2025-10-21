#!/bin/bash
set -e

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本，例如: sudo $0"
    exit 1
fi

REPO="heiher/hev-socks5-tunnel"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/tun2socks"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE_FILE="/etc/systemd/system/tun2socks.service"
BINARY_PATH="$INSTALL_DIR/tun2socks"

# 获取下载链接
DOWNLOAD_URL=$(curl -s https://proxy.lblog.net/https://api.github.com/repos/$REPO/releases/latest | grep "browser_download_url" | grep "linux-x86_64" | cut -d '"' -f 4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "未找到下载链接，可能网络问题或项目结构改变。"
    exit 1
fi

echo "正在下载 tun2socks..."
curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"
chmod +x "$BINARY_PATH"

# 提示用户输入配置参数
echo
echo "请输入你的 SOCKS5 代理配置："

read -p "请输入 SOCKS5 地址（支持 IPv4/IPv6，例如 127.0.0.1 或 2a14:67c0:100::af）: " SOCKS_ADDR
read -p "请输入 SOCKS5 端口（例如 40000）: " SOCKS_PORT
read -p "请输入用户名（留空可不填）: " SOCKS_USER
read -p "请输入密码（留空可不填）: " SOCKS_PASS

# 创建配置目录
mkdir -p "$CONFIG_DIR"

# 写入配置文件
cat > "$CONFIG_FILE" <<EOF
tunnel:
  name: tun0
  mtu: 8500
  multi-queue: true
  ipv4: 198.18.0.1

socks5:
  port: $SOCKS_PORT
  address: '$SOCKS_ADDR'
  udp: 'udp'
  username: '$SOCKS_USER'
  password: '$SOCKS_PASS'
EOF

echo -e "\n已生成配置文件：$CONFIG_FILE"

# 写入 systemd 服务文件
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tun2Socks Tunnel Service
After=network.target

[Service]
Type=simple
ExecStartPre=/sbin/ip tuntap add dev tun0 mode tun || true
ExecStartPre=/sbin/ip link set tun0 up
ExecStart=$BINARY_PATH --config=$CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "重新加载 systemd..."
systemctl daemon-reload
systemctl enable tun2socks.service

echo
echo "✅ 安装完成，可运行以下命令启动服务："
echo "sudo systemctl start tun2socks.service"
echo "查看状态：sudo systemctl status tun2socks.service"
