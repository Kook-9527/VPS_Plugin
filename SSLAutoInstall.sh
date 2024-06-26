#!/bin/bash

#该shell脚本用于更加方便地签发和安装Let's Encrypt证书
#这个shell脚本现在提供两种方法来签发证书
#   1.Standalone模式：最简单的方式签发证书，但需要保持端口始终开放
#   2.DNS API模式：最强大的方法，但稍微复杂一些，可以帮助你签发通配符证书
#     无需保持端口开放

#无论采用何种方法，证书将在60天内自动续签，无需担心过期问题
#更多信息，请查看acme官方文档。

#作者：FranzKafka
#日期：2022-08-18
#版本：0.0.1

#一些常量
OS_CHECK=''
CERT_DOMAIN=''
CERT_DEFAULT_INSTALL_PATH='/root/cert/'

#一些基本设置
plain='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'

#日志函数，用于输出调试信息
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

#日志函数，用于输出错误信息
function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

#日志函数，用于输出一般信息
function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

#检查是否为root用户
LOGI "权限检查..."
currentUser=$(whoami)
LOGD "当前用户是 $currentUser"
if [ $currentUser != "root" ]; then
    LOGE "注意:请检查是否为root用户，请检查是否为root用户"
    exit 1
fi

#检查操作系统类型
LOGI "系统类型检查..."
if [[ -f /etc/redhat-release ]]; then
    OS_CHECK="centOS_CHECK"
elif cat /etc/issue | grep -Eqi "debian"; then
    OS_CHECK="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    OS_CHECK="ubuntu"
elif cat /etc/issue | grep -Eqi "centOS_CHECK|red hat|redhat"; then
    OS_CHECK="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    OS_CHECK="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    OS_CHECK="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    OS_CHECK="centos"
else
    LOGE "未检测到系统版本，请联系脚本作者!\n" && exit 1
fi

#用于用户确认的函数
confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

#安装acme.sh脚本的函数
install_acme() {
    cd ~
    LOGI "开始安装acme脚本..."
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "acme安装失败"
        return 1
    else
        LOGI "acme安装成功"
    fi
    return 0
}

#域名合法性检查函数
domain_valid_check() {
    local domain=""
    read -p "请输入你的域名:" domain
    LOGD "你输入的域名为:${domain}，正在进行域名合法性校验..."
    #检查是否已有对应域名的证书
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ ${currentCert} == ${domain} ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "域名合法性校验失败，当前环境已有对应域名证书，不可重复申请，当前证书详情:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "证书有效性校验通过..."
        CERT_DOMAIN=${domain}
    fi
}

#设置证书安装路径函数
install_path_set() {
    cd ~
    local InstallPath=''
    read -p "请输入证书安装路径:" InstallPath
    if [[ -n ${InstallPath} ]]; then
        LOGD "你输入的路径为:${InstallPath}"
    else
        InstallPath=${CERT_DEFAULT_INSTALL_PATH}
        LOGI "输入路径为空，将采用默认路径:${CERT_DEFAULT_INSTALL_PATH}"
    fi

    if [ ! -d "${InstallPath}" ]; then
        mkdir -p "${InstallPath}"
    else
        rm -rf "${InstallPath}"
        mkdir -p "${InstallPath}"
    fi

    if [ $? -ne 0 ]; then
        LOGE "设置安装路径失败，请确认"
        exit 1
    fi
    CERT_DEFAULT_INSTALL_PATH=${InstallPath}
}

#端口检查函数
port_check() {
    if [ $# -ne 1 ]; then
        LOGE "参数错误，脚本退出..."
        exit 1
    fi
    port_progress=$(lsof -i:$1 | wc -l)
    if [[ ${port_progress} -ne 0 ]]; then
        LOGD "检测到当前端口存在占用，请更换端口或者停止该进程"
        return 1
    fi
    return 0
}

#证书申请入口函数
ssl_cert_issue() {
    local method=""
    echo -E ""
    LOGI "该脚本目前提供两种方式实现证书签发"
    LOGI "方式1:acme standalone模式，需要保持端口开放"
    LOGI "方式2:acme DNS API模式，需要提供Cloudflare Global API Key"
    LOGI "如域名属于免费域名，则推荐使用方式1进行申请"
    LOGI "如域名非免费域名且使用Cloudflare进行解析使用方式2进行申请"
    read -p "请选择你想使用的方式，请输入数字1或者2后回车": method
    LOGI "你所使用的方式为${method}"

    if [ "${method}" == "1" ]; then
        ssl_cert_issue_standalone
    elif [ "${method}" == "2" ]; then
        ssl_cert_issue_by_cloudflare
    else
        LOGE "输入无效，请检查你的输入，脚本将退出..."
        exit 1
    fi
}

#Standalone模式的证书申请方法
ssl_cert_issue_standalone() {
    #首先安装acme.sh
    install_acme
    if [ $? -ne 0 ]; then
        LOGE "无法安装acme，请检查错误日志"
        exit 1
    fi
    #其次安装socat
    if [[ x"${OS_CHECK}" == x"centos" ]]; then
        yum install socat -y
    else
        apt install socat -y
    fi
    if [ $? -ne 0 ]; then
        LOGE "无法安装socat，请检查错误日志"
        exit 1
    else
        LOGI "socat安装成功..."
    fi
    #创建目录用于安装证书
    install_path_set
    #域名合法性检查
    domain_valid_check
    #获取需要的端口
    local WebPort=80
    read -p "请输入你所希望使用的端口，如回车将使用默认80端口:" WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "你所选择的端口${WebPort}为无效值，将使用默认80端口进行申请"
        WebPort=80
    fi
    LOGI "将会使用${WebPort}端口进行证书申请，现进行端口检测，请确保端口处于开放状态..."
    #打开端口并终止占用的进程
    port_check ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "端口检测失败，请确保不被其他程序占用，脚本退出..."
        exit 1
    else
        LOGI "端口检测成功..."
    fi

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${CERT_DOMAIN} --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "证书申请失败，原因请参见报错信息"
        exit 1
    else
        LOGI "证书申请成功，开始安装证书..."
    fi
    #安装证书
    ~/.acme.sh/acme.sh --installcert -d ${CERT_DOMAIN} --ca-file /root/cert/ca.cer \
    --cert-file /root/cert/${CERT_DOMAIN}.cer --key-file /root/cert/${CERT_DOMAIN}.key \
    --fullchain-file /root/cert/fullchain.cer

    if [ $? -ne 0 ]; then
        LOGE "证书安装失败，脚本退出"
        exit 1
    else
        LOGI "证书安装成功，开启自动更新..."
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动更新设置失败，脚本退出"
        chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
        exit 1
    else
        LOGI "证书已安装且已开启自动更新，具体信息如下"
        ls -lah ${CERT_DEFAULT_INSTALL_PATH}
        chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
    fi
}

#DNS API模式的证书申请方法
ssl_cert_issue_by_cloudflare() {
    echo -E ""
    LOGI "该脚本将使用Acme脚本申请证书，使用时需保证:"
    LOGI "1.知晓Cloudflare 注册邮箱"
    LOGI "2.知晓Cloudflare Global API Key"
    LOGI "3.域名已通过Cloudflare进行解析到当前服务器"
    confirm "我已确认以上内容[y/n]" "y"
    if [ $? -eq 0 ]; then
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "无法安装acme，请检查错误日志"
            exit 1
        fi
        #创建目录用于安装证书
        install_path_set
        #设置DNS API
        CF_GlobalKey=""
        CF_AccountEmail=""

        #域名合法性检查
        domain_valid_check
        LOGD "请设置API密钥:"
        read -p "输入你的密钥:" CF_GlobalKey
        LOGD "你的API密钥为:${CF_GlobalKey}"
        LOGD "请设置注册邮箱:"
        read -p "输入你的邮箱:" CF_AccountEmail
        LOGD "你的注册邮箱为:${CF_AccountEmail}"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [ $? -ne 0 ]; then
            LOGE "修改默认CA为Let's Encrypt失败，脚本退出"
            exit 1
        fi
        export CF_Key="${CF_GlobalKey}"
        export CF_Email=${CF_AccountEmail}
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CERT_DOMAIN} -d *.${CERT_DOMAIN} --log
        if [ $? -ne 0 ]; then
            LOGE "证书签发失败，脚本退出"
            exit 1
        else
            LOGI "证书签发成功，安装中..."
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CERT_DOMAIN} -d *.${CERT_DOMAIN} --ca-file /root/cert/ca.cer \
        --cert-file /root/cert/${CERT_DOMAIN}.cer --key-file /root/cert/${CERT_DOMAIN}.key \
        --fullchain-file /root/cert/fullchain.cer
        if [ $? -ne 0 ]; then
            LOGE "证书安装失败，脚本退出"
            exit 1
        else
            LOGI "证书安装成功，开启自动更新..."
        fi
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "自动更新设置失败，脚本退出"
            ls -lah cert
            chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
            exit 1
        else
            LOGI "证书已安装且已开启自动更新，具体信息如下"
            ls -lah ${CERT_DEFAULT_INSTALL_PATH}
            chmod 755 ${CERT_DEFAULT_INSTALL_PATH}
        fi
    else
        LOGI "脚本退出..."
        exit 1
    fi
}

ssl_cert_issue
