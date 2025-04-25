#!/bin/bash

PORT=23100

function install_iperf3() {
    echo "正在安装 iperf3..."
    apt update
    apt install -y iperf3
    echo "创建 systemd 服务..."
    cat >/etc/systemd/system/iperf3.service <<EOF
[Unit]
Description=iperf3 Server on port ${PORT}
After=network.target

[Service]
ExecStart=/usr/bin/iperf3 -s -p ${PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable iperf3
    systemctl start iperf3
    echo "iperf3 安装完成，服务端正在监听端口 ${PORT}。"
}

function uninstall_iperf3() {
    echo "正在卸载 iperf3..."
    systemctl stop iperf3
    systemctl disable iperf3
    rm -f /etc/systemd/system/iperf3.service
    systemctl daemon-reload
    apt remove --purge -y iperf3
    apt autoremove -y
    echo "iperf3 已成功卸载。"
}

function client_test() {
    # 检查 iperf3 是否存在
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo "未检测到 iperf3，正在自动安装..."
        apt update
        apt install -y iperf3
    fi

    read -p "请输入服务端 IPv4/IPv6 地址: " SERVER_IP
    if [[ -z "$SERVER_IP" ]]; then
        echo "IP地址不能为空。"
        return
    fi
    echo "开始向 $SERVER_IP 测试 TCP 带宽（端口：$PORT）..."
    iperf3 -c $SERVER_IP -p $PORT
}

function show_menu() {
    echo "=============================="
    echo " iperf3 一键管理脚本"
    echo " 默认端口：$PORT"
    echo "=============================="
    echo "1. 安装并启动iperf3服务端"
    echo "2. 客户端测速（连接远程服务器）"
    echo "3. 卸载iperf3"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项 [0-3]: " choice
    case "$choice" in
        1) install_iperf3 ;;
        2) client_test ;;
        3) uninstall_iperf3 ;;
        0) exit 0 ;;
        *) echo "无效输入，请重新选择。" && sleep 1 && show_menu ;;
    esac
}

show_menu
