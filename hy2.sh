#!/bin/bash

# 安装hy2+端口跳跃插件
sudo apt update && sudo apt install -y iptables && bash <(curl -fsSL https://get.hy2.sh/)

# 申请必应自签证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=bing.com" -days 36500 && sudo chown hysteria /etc/hysteria/server.key && sudo chown hysteria /etc/hysteria/server.crt

# 设置脚本为可执行
chmod +x setup_hy2.sh

# 手动设置的变量
read -p "请输入本地监听端口（默认为443）: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-443}

read -p "请设置端口跳跃起始值（默认为60000）: " UDP_PORT_RANGE_START
UDP_PORT_RANGE_START=${UDP_PORT_RANGE_START:-60000}

read -p "请设置端口跳跃结束值（默认为65000）: " UDP_PORT_RANGE_END
UDP_PORT_RANGE_END=${UDP_PORT_RANGE_END:-65000}

read -p "请输入认证密码: " PASSWORD
PASSWORD=${PASSWORD:-$(< /dev/urandom tr -dc A-Za-z0-9 | head -c20)}


# 设置端口跳跃
sudo iptables -t nat -A PREROUTING -i eth0 -p udp --dport $UDP_PORT_RANGE_START:$UDP_PORT_RANGE_END -j DNAT --to-destination :$LOCAL_PORT && sudo ip6tables -t nat -A PREROUTING -i eth0 -p udp --dport $UDP_PORT_RANGE_START:$UDP_PORT_RANGE_END -j DNAT --to-destination :$LOCAL_PORT

# ⑥端口跳跃设置开机自启
sudo tee -a /etc/iptables/rules.v4 >/dev/null <<EOF
*nat
-A PREROUTING -i eth0 -p udp --dport $UDP_PORT_RANGE_START:$UDP_PORT_RANGE_END -j DNAT --to-destination :$LOCAL_PORT
COMMIT
EOF

sudo tee -a /etc/iptables/rules.v6 >/dev/null <<EOF
*nat
-A PREROUTING -i eth0 -p udp --dport $UDP_PORT_RANGE_START:$UDP_PORT_RANGE_END -j DNAT --to-destination :$LOCAL_PORT
COMMIT
EOF

# 服务端配置
cat << EOF > /etc/hysteria/config.yaml
listen: :$LOCAL_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

quic:
  initStreamReceiveWindow: 26843545
  maxStreamReceiveWindow: 26843545
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

udpIdleTimeout: 60s

auth:
  type: password
  password: $PASSWORD # 设置认证密码

masquerade:
  type: proxy
  proxy:
    url: https://bing.com # 伪装网址
    rewriteHost: true
EOF

# 修改系统缓冲区
sudo sysctl -w net.core.rmem_max=16777216 net.core.wmem_max=16777216

# 启动 Hysteria2+开机自启
systemctl start hysteria-server.service && systemctl enable hysteria-server.service

# 设置每天4点检测更新
echo -e "$(crontab -l)\n0 4 * * * /bin/bash -c 'bash <(curl -fsSL https://get.hy2.sh/)' " | crontab -
