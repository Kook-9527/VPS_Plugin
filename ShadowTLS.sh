#!/bin/bash

# 检查并安装 jq（如果没有安装的话）
if ! command -v jq &>/dev/null; then
    echo "jq 未安装，正在安装 jq..."
    if [[ -n "$(command -v apt)" ]]; then
        sudo apt-get update && sudo apt-get install -y jq  # Debian/Ubuntu 系统
    elif [[ -n "$(command -v yum)" ]]; then
        sudo yum install -y jq  # CentOS/RHEL 系统
    else
        echo "无法自动安装 jq，请手动安装 jq 工具。"
        exit 1
    fi
fi

# 检查是否已经安装了 shadow-tls
if command -v shadow-tls &>/dev/null; then
    SHADOW_TLS_INSTALLED=true
else
    SHADOW_TLS_INSTALLED=false
fi

# 显示主菜单
echo -e "┌─────────────────────────────────────────────────────────────┐"
echo -e "│                                                             │"
echo -e "│          ShadowTLSv3一键安装脚本  by：Kook-9527             │"
echo -e "│                                                             │"
echo -e "└─────────────────────────────────────────────────────────────┘"
echo -e "————————————————————"
echo "1. 安装 ShadowTLSv3"
echo "2. 更新 ShadowTLSv3"
echo "3. 卸载 ShadowTLSv3"
echo -e "————————————————————"
echo "4. 修改配置"
echo "5. 重启服务"
echo "6. 停止服务"
echo -e "————————————————————"
echo "0. 退出脚本"
echo -e "————————————————————" && echo
read -p "请输入选项【0-6】: " choice

# 根据用户选择执行相应操作
case $choice in
    1)
        # 检查是否已经安装
        if $SHADOW_TLS_INSTALLED; then
            echo "ShadowTLSv3 已经安装，跳过安装步骤。"
            echo -e "————————————————————" && echo
            sleep 2
            exec $0
        fi

        # 获取 GitHub 上 ShadowTLSv3 最新版本号
        LATEST_VERSION=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)

        if [[ -z "$LATEST_VERSION" ]]; then
            echo "无法获取最新版本信息，请检查网络连接或 GitHub API 限制。"
            exit 1
        fi

        echo "最新版本为: $LATEST_VERSION"

        # 自动检测架构并下载对应版本
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/$LATEST_VERSION/shadow-tls-x86_64-unknown-linux-musl"
        elif [[ "$ARCH" == "arm"* ]]; then
            DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/$LATEST_VERSION/shadow-tls-arm-unknown-linux-musleabi"
        else
            echo "不支持的架构: $ARCH"
            exit 1
        fi

        # 下载并安装 shadow-tls
        echo "下载 ShadowTLSv3 最新版 $LATEST_VERSION ..."
        curl -L $DOWNLOAD_URL -o /usr/local/bin/shadow-tls
        chmod a+x /usr/local/bin/shadow-tls

        # 手动输入原来节点的端口
        while [[ -z "$SERVER_PORT" ]]; do
            read -p "请输入原来节点的端口: " SERVER_PORT
        done

        # 提示用户设置 ShadowTLSv3 端口，按回车则随机生成
        read -p "请设置 ShadowTLSv3 端口（按回车则随机生成）: " TLS_PORT
        TLS_PORT=${TLS_PORT:-$(shuf -i 20000-65000 -n 1)}  # 随机生成端口

        # 生成符合要求的 16 位随机密码（大小写+数字）
        read -p "请设置 ShadowTLSv3 密码（按回车则随机生成）: " PASSWORD
        PASSWORD=${PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}

        # 伪装域名，按回车使用默认值
        read -p "请输入支持TLS1.3的伪装域名（按回车则默认为 mp.weixin.qq.com）: " FAKE_DOMAIN
        FAKE_DOMAIN=${FAKE_DOMAIN:-"mp.weixin.qq.com"}

        # 创建并配置 systemd 服务
        echo "配置 systemd 服务..."
        cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767 
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c ulimit -n 51200
ExecStart=shadow-tls --fastopen --v3 --strict server --wildcard-sni=authed --listen [::]:$TLS_PORT --server 127.0.0.1:$SERVER_PORT --tls $FAKE_DOMAIN:443 --password $PASSWORD

[Install]
WantedBy=multi-user.target
EOF

        # 重新加载 systemd 配置并启动服务
        echo "重载 systemd 服务并启动..."
        systemctl daemon-reload
        systemctl enable --now shadow-tls

        echo -e "安装并启动 ShadowTLSv3 完成！\n"
        echo -e "———————————————————————————————————————"
        echo "ShadowTLSv3 端口:  $TLS_PORT"
        echo "ShadowTLSv3 密码:  $PASSWORD"
        echo "ShadowTLSv3 伪装域名:  $FAKE_DOMAIN"
        echo -e "———————————————————————————————————————"
        ;;
    2)
        # 获取 GitHub 上 ShadowTLSv3 最新版本号
        LATEST_VERSION=$(curl -s https://api.github.com/repos/ihciah/shadow-tls/releases/latest | jq -r .tag_name)

        if [[ -z "$LATEST_VERSION" ]]; then
            echo "无法获取最新版本信息，请检查网络连接或 GitHub API 限制。"
            exit 1
        fi

        echo "最新版本为: $LATEST_VERSION"

        # 自动检测架构并下载对应版本
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/$LATEST_VERSION/shadow-tls-x86_64-unknown-linux-musl"
        elif [[ "$ARCH" == "arm"* ]]; then
            DOWNLOAD_URL="https://github.com/ihciah/shadow-tls/releases/download/$LATEST_VERSION/shadow-tls-arm-unknown-linux-musleabi"
        else
            echo "不支持的架构: $ARCH"
            exit 1
        fi

        # 下载并安装 shadow-tls
        echo "下载 ShadowTLSv3 最新版 $LATEST_VERSION ..."
        curl -L $DOWNLOAD_URL -o /usr/local/bin/shadow-tls
        chmod a+x /usr/local/bin/shadow-tls

        echo "更新 ShadowTLSv3 完成！"
        ;;
    3)
        # 完全卸载 ShadowTLSv3
        echo "正在卸载 ShadowTLSv3..."

        # 停止并禁用服务
        systemctl stop shadow-tls
        systemctl disable shadow-tls

        # 删除服务文件
        rm -f /etc/systemd/system/shadow-tls.service

        # 删除 shadow-tls 可执行文件
        rm -f /usr/local/bin/shadow-tls

        # 重载 systemd 配置
        systemctl daemon-reload

        echo "ShadowTLSv3 已完全卸载。"
        ;;
    4)
        # 修改配置
        echo "修改 ShadowTLSv3 配置..."

        # 手动输入原来节点的端口
        while [[ -z "$SERVER_PORT" ]]; do
            read -p "请输入原来节点的端口: " SERVER_PORT
        done

        # 提示用户设置 ShadowTLSv3 端口，按回车则随机生成
        read -p "请设置 ShadowTLSv3 端口（按回车则随机生成）: " TLS_PORT
        TLS_PORT=${TLS_PORT:-$(shuf -i 20000-65000 -n 1)}  # 随机生成端口

        # 生成符合要求的 16 位随机密码（大小写+数字）
        read -p "请设置 ShadowTLSv3 密码（按回车则随机生成）: " PASSWORD
        PASSWORD=${PASSWORD:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}

        # 伪装域名，按回车使用默认值
        read -p "请输入支持TLS1.3的伪装域名（按回车则默认为 mp.weixin.qq.com）: " FAKE_DOMAIN
        FAKE_DOMAIN=${FAKE_DOMAIN:-"mp.weixin.qq.com"}

        # 更新 systemd 服务文件
        echo "更新 systemd 服务..."
        cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
LimitNOFILE=32767 
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c ulimit -n 51200
ExecStart=shadow-tls --fastopen --v3 --strict server --wildcard-sni=authed --listen [::]:$TLS_PORT --server 127.0.0.1:$SERVER_PORT --tls $FAKE_DOMAIN:443 --password $PASSWORD

[Install]
WantedBy=multi-user.target
EOF

        # 重新加载 systemd 配置并重启服务
        echo "重载 systemd 配置并重启服务..."
        systemctl daemon-reload
        systemctl restart shadow-tls

        echo -e "———————————————————————————————————————"
        echo "ShadowTLSv3 端口:  $TLS_PORT"
        echo "ShadowTLSv3 密码:  $PASSWORD"
        echo "ShadowTLSv3 伪装域名:  $FAKE_DOMAIN"
        echo -e "———————————————————————————————————————"
        ;;
    5)
        # 重启服务
        echo "正在重启 ShadowTLSv3 服务..."
        systemctl restart shadow-tls
        echo "ShadowTLSv3 服务已重启。"
        ;;
    6)
        # 停止服务
        echo "正在停止 ShadowTLSv3 服务..."
        systemctl stop shadow-tls
        echo "ShadowTLSv3 服务已停止。"
        ;;
    0)
        echo "退出脚本。"
        exit 0
        ;;
    *)
        echo "无效选项，请重新选择。"
        ;;
esac
