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
UDP_PORT_RANGE_START=${UDP_PORT_RANGE_START:-50000}

read -p "请设置端口跳跃结束值（默认为65000）: " UDP_PORT_RANGE_END
UDP_PORT_RANGE_END=${UDP_PORT_RANGE_END:-60000}

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

# --------------------
# 节点代码生成
# --------------------

# 获取本机 IP
local_ip=$(hostname -I | awk '{print $1}') || local_ip=$(hostname -I -6 | awk '{print $1}')
if [ -z "$local_ip" ]; then
  log_message "无法获取本机 IP 地址" && exit 1
fi

# 从配置文件中提取监听端口、密码和自签证书域名
listen_port=$(grep "^listen" /etc/hysteria/config.yaml | awk '{print $2}' | cut -d ':' -f2)
password=$(grep "password: " /etc/hysteria/config.yaml | awk '{print $2}')
sni_domain=$(openssl x509 -noout -subject -in /etc/hysteria/server.crt | sed -n '/^subject/s/^.*CN=//p')

# 检查证书域名是否为空，默认bing.com
sni_domain=${sni_domain:-bing.com}

# 生成并显示节点代码
universal_node="hysteria2://$password@$local_ip:$listen_port/?insecure=1&sni=$sni_domain&mport=$UDP_PORT_RANGE_START-$UDP_PORT_RANGE_END#Hy2_$local_ip"
loon_node="Hy2_$local_ip = Hysteria2,$local_ip,$listen_port,\"$password\",sni=$sni_domain,skip-cert-verify=true,download-bandwidth=250"
surge_node="Hy2_$local_ip = Hysteria2,$local_ip,$listen_port,password=$password,port-hopping=$UDP_PORT_RANGE_START-$UDP_PORT_RANGE_END,port-hopping-interval=30,sni=$sni_domain,skip-cert-verify=true,download-bandwidth=250"

echo -e "\n\033[1;32m=============================================================="
echo -e "\n\033[1;32m通用格式节点: \n$universal_node\033[0m"
echo -e "\n\033[1;32mLoon格式节点: \n$loon_node\033[0m"
echo -e "\n\033[1;32mSurge格式节点: \n$surge_node\033[0m\n"
echo -e "==============================================================\033[0m\n"
