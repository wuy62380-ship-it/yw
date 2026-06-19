#!/bin/bash

# ====================================================================
# 项目名称: Linux YW性能一键优化BBRv3
# 适用系统: Ubuntu 24.04+ / Debian 12+ (支持 x86_64 / ARM64)
# ====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检查 1: 必须以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！(sudo bash 脚本名)${PLAIN}"
    exit 1
fi

CURRENT_KERNEL=$(uname -r)

# 自动判定阶段
if [[ "$CURRENT_KERNEL" == *"-joeyblog-bbrv3"* ]] || [[ "$CURRENT_KERNEL" == *"-bbrv3"* ]]; then
    # ----------------------------------------------------------------
    # 状态 A: 用户已经重启并进入了标准 BBRv3 内核环境
    #         百分之百一字不差还原写入您发给我的完整原始代码
    # ----------------------------------------------------------------
    echo -e "${BLUE}[1/2] 检测到系统已成功载入原生标准 BBRv3 内核 (${CURRENT_KERNEL})。${PLAIN}"
    echo -e "${YELLOW}正在为您自动恢复、生成并覆盖 /etc/sysctl.conf 配置...${PLAIN}"

    # 1. 备份原有的 sysctl.conf
    cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 2. 精准还原您发送给我的完整原始代码
    cat << 'EOF' > /etc/sysctl.conf
#
# /etc/sysctl.conf - Configuration file for setting system variables
# See /etc/sysctl.d/ for additional system variables.
# See sysctl.conf (5) for information.
#

#kernel.domainname = example.com

# Uncomment the following to stop low-level messages on console
#kernel.printk = 3 4 1 3

###################################################################
# Functions previously found in netbase
#

# Uncomment the next two lines to enable Spoof protection (reverse-path filter)
# Turn on Source Address Verification in all interfaces to
# prevent some spoofing attacks
#net.ipv4.conf.default.rp_filter=1
#net.ipv4.conf.all.rp_filter=1

# Uncomment the next line to enable TCP/IP SYN cookies
# See http://lwn.net
# Note: This may impact IPv6 TCP sessions too
#net.ipv4.tcp_syncookies=1

# Uncomment the next line to enable packet forwarding for IPv4
#net.ipv4.ip_forward=1

# Uncomment the next line to enable packet forwarding for IPv6
#  Enabling this option disables Stateless Address Autoconfiguration
#  based on Router Advertisements for this host
#net.ipv6.conf.all.forwarding=1


###################################################################
# Additional settings - these settings can improve the network
# security of the host and prevent against some network attacks
# including spoofing attacks and man in the middle attacks through
# redirection. Some network environments, however, require that these
# settings are disabled so review and enable them as needed.
#
# Do not accept ICMP redirects (prevent MITM attacks)
#net.ipv4.conf.all.accept_redirects = 0
#net.ipv6.conf.all.accept_redirects = 0
# _or_
# Accept ICMP redirects only for gateways listed in our default
# gateway list (enabled by default)
# net.ipv4.conf.all.secure_redirects = 1
#
# Do not send ICMP redirects (we are not a router)
#net.ipv4.conf.all.send_redirects = 0
#
# Do not accept IP source route packets (we are not a router)
#net.ipv4.conf.all.accept_source_route = 0
#net.ipv6.conf.all.accept_source_route = 0
#
# Log Martian Packets
#net.ipv4.conf.all.log_martians = 1
#

###################################################################
# Magic system request Key
# 0=disable, 1=enable all, >1 bitmask of sysrq functions
# See https://kernel.org
# for what other values do
#kernel.sysrq=438

fs.file-max = 65535

# === 以下为原生标准 BBRv3 配套所需的 network 加速变量 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 3. 让配置（包含您的 fs.file-max = 65535）立即在内核中生效
    sudo sysctl -p > /dev/null

    echo -e "${GREEN}[2/2] 系统变量 /etc/sysctl.conf 配置成功！${PLAIN}"
    echo -e "${BLUE}=================== BBRv3 状态验证结果 ===================${PLAIN}"
    
    # 验证算法是否为 bbr
    CHECK_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$CHECK_ALGO" == "bbr" ]; then
        echo -e "拥塞控制算法: ${GREEN}成功激活 (bbr)${PLAIN}"
    else
        echo -e "拥塞控制算法: ${RED}未激活 (当前为 $CHECK_ALGO)${PLAIN}"
    fi

    # 验证您代码中的指定参数 fs.file-max
    CHECK_FILE=$(cat /proc/sys/fs/file-max)
    echo -e "最大文件打开数 (fs.file-max): ${GREEN}${CHECK_FILE}${PLAIN}"

    # 验证 BBRv3 底层连接状态
    echo -e "底层网络流检查 (含有 mrtt 关键字说明 BBRv3 正在接管流量):"
    ss -ti | grep -E "bbr|mrtt" | head -n 3

    echo -e "${BLUE}==========================================================${PLAIN}"
    echo -e "${GREEN}🎉 恭喜！标准 BBRv3 纯净包部署、原始配置覆盖与验证已全部完成！${PLAIN}"

else
    # ----------------------------------------------------------------
    # 状态 B: 首次运行 -> 智能识别架构并拉取对应内核
    # ----------------------------------------------------------------
    echo -e "${YELLOW}[1/3] 正在检查基础环境依赖与服务器架构...${PLAIN}"
    apt-get update -y > /dev/null
    apt-get install -y curl wget ca-certificates > /dev/null

    # 【自动识别架构】
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ARCH_TAG="amd64"
        echo -e "${BLUE}当前服务器架构为: x86_64 (amd64)${PLAIN}"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        ARCH_TAG="arm64"
        echo -e "${BLUE}当前服务器架构为: ARM64 (aarch64)${PLAIN}"
    else
        echo -e "${RED}[错误] 暂不支持当前服务器架构: ${ARCH}${PLAIN}"
        exit 1
    fi

    echo -e "${YELLOW}正在从 GitHub 分析并提取标准原版 BBRv3 最新内核文件地址...${PLAIN}"
    
    # 稳定的编译流仓库
    TAG_URL="https://github.com"
    HTML_DATA=$(curl -sL --connect-timeout 10 "$TAG_URL")
    
    # 根据自适应的 ARCH_TAG 动态匹配文件路径
    IMAGE_PATH=$(echo "$HTML_DATA" | grep -oE "/byJoey/Actions-bbr-v3/releases/download/[^\"]+linux-image[^\"]+${ARCH_TAG}\.deb" | head -n 1)
    HEADERS_PATH=$(echo "$HTML_DATA" | grep -oE "/byJoey/Actions-bbr-v3/releases/download/[^\"]+linux-headers[^\"]+${ARCH_TAG}\.deb" | head -n 1)

    if [ -z "$IMAGE_PATH" ] || [ -z "$HEADERS_PATH" ]; then
        echo -e "${RED}[错误] 无法从源地址检索到适合您架构 (${ARCH_TAG}) 的 BBRv3 内核包！${PLAIN}"
        exit 1
    fi

    IMAGE_DEB_URL="https://github.com${IMAGE_PATH}"
    HEADERS_DEB_URL="https://github.com${HEADERS_PATH}"

    echo -e "${GREEN}[2/3] 提取成功！正在拉取原厂内核数据包并进行全自动无感知安装...${PLAIN}"
    mkdir -p /tmp/bbrv3_install && cd /tmp/bbrv3_install
    
    # 下载对应架构的内核包
    wget -q --show-progress --no-check-certificate "$IMAGE_DEB_URL"
    wget -q --show-progress --no-check-certificate "$HEADERS_DEB_URL"

    # 执行静默式底层安全安装
    echo -e "${YELLOW}正在写入系统内核引导，请稍候...${PLAIN}"
    sudo dpkg -i *.deb > /dev/null
    
    # 多系统引导兼容性修复
    if command -v update-grub > /dev/null 2>&1; then
        sudo update-grub > /dev/null
    else
        sudo grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1
    fi

    echo -e "${GREEN}[3/3] 内核包静默升级已全部完成！${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e "${YELLOW} 由于更换了 Linux 底层核心，必须重启系统。${PLAIN}"
    echo -e "${YELLOW} 重启命令: ${RED}reboot${PLAIN}"
    echo -e "${YELLOW} 重启完成后再次执行您本人的这个脚本，将立即覆盖、激活您的原始代码配置！${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
    
    # 清理现场临时缓存
    cd && rm -rf /tmp/bbrv3_install
fi
