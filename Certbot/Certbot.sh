#!/bin/bash

# 停止nginx服务
sudo systemctl stop nginx

# 更新软件包列表并安装 certbot
apt update -y && apt install -y certbot

# 获取域名
read -p "请输入已解析好的域名（多个域名用空格分隔）：" domains

# 检查域名是否为空
if [ -z "$domains" ]; then
  echo "域名为空，脚本已自动退出！"
  exit 1
fi

# 循环处理每个域名
for domain in $domains; do
  # 去除域名两端的空格
  domain=$(echo $domain | sed 's/^\s+|\s+$//g')

  # 申请证书
  certbot certonly --standalone -d $domain --email you@email.com --agree-tos --no-eff-email --force-renewal

  # 检查证书是否申请成功
  if [ $? -ne 0 ]; then
    echo "申请证书失败：$domain"
    continue
  fi

  # 输出证书存放目录
  echo "证书存放目录：/etc/letsencrypt/live/$domain"

  # 复制证书文件到 /root/cert/ 目录
  mkdir -p /root/cert/
  cp /etc/letsencrypt/live/$domain/*.pem /root/cert/
done

# 下载自动续签脚本
if [ ! -f "auto_cert_renewal.sh" ]; then
  curl -O https://raw.githubusercontent.com/Kook-9527/VPS_Plugin/refs/heads/main/Certbot/auto_cert_renewal.sh
fi

# 赋予自动续签脚本可执行权限
chmod +x auto_cert_renewal.sh

# 执行自动续签脚本
./auto_cert_renewal.sh

# 定时执行脚本
if ! crontab -l | grep -q '/auto_cert_renewal.sh'; then
    crontab -l > /tmp/crontab_tmp
    echo -e "0 0 * * * cd ~ && ./auto_cert_renewal.sh" >> /tmp/crontab_tmp
    crontab /tmp/crontab_tmp
    rm /tmp/crontab_tmp
fi

# 启动nginx服务
sudo systemctl start nginx
