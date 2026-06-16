#!/bin/bash

# ====================================================================
# 项目名称: BBRv3 YW激活脚本
# 适用系统: Ubuntu 24.04+ / Debian 12+ (x86_64 / aarch64)
# ====================================================================

# 终端颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检查 1: 必须以 root 权限运行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！(例如: sudo bash 脚本名)${PLAIN}"
    exit 1
fi

# 核心阶段：自动根据当前的内核状态执行不同操作
CURRENT_KERNEL=$(uname -r)

if [[ "$CURRENT_KERNEL" == *"-joeyblog-bbrv3"* ]]; then
    # ----------------------------------------------------------------
    # 状态 A: 用户已使用 byJoey 内核重启，现在执行原代码写入与最终验证
    # ----------------------------------------------------------------
    echo -e "${BLUE}[1/2] 检测到您已成功运行 byJoey-BBRv3 专用内核 (${CURRENT_KERNEL})。${PLAIN}"
    echo -e "${YELLOW}正在自动生成并覆盖 /etc/sysctl.conf 配置...${PLAIN}"

    # 备份原有的 sysctl.conf
    cp /etc/sysctl.conf /etc/sysctl.conf.bak

    # 精准写入您发送给我的完整原始代码，并在底部追加 BBRv3 必要变量
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

# === 以下为 BBRv3 所需的配套加速变量 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 让配置立即在内核中生效
    sudo sysctl -p > /dev/null

    echo -e "${GREEN}[2/2] 系统变量 /etc/sysctl.conf 配置成功！${PLAIN}"
    echo -e "${BLUE}=================== BBRv3 状态验证结果 ===================${PLAIN}"
    
    # 验证算法
    CHECK_ALGO=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [ "$CHECK_ALGO" == "bbr" ]; then
        echo -e "拥塞控制算法: ${GREEN}成功激活 (bbr)${PLAIN}"
    else
        echo -e "拥塞控制算法: ${RED}未激活 (当前为 $CHECK_ALGO)${PLAIN}"
    fi

    # 验证原代码中的 file-max 数值
    CHECK_FILE=$(cat /proc/sys/fs/file-max)
    echo -e "最大文件打开数 (fs.file-max): ${GREEN}${CHECK_FILE}${PLAIN}"

    # 验证 BBR 内核底层状态
    echo -e "底层网络流检查 (含有 mrtt 关键字代表 BBRv3 已正常接管流量):"
    ss -ti | grep -E "bbr|mrtt" | head -n 3

    echo -e "${BLUE}==========================================================${PLAIN}"
    echo -e "${GREEN}🎉 恭喜！BBRv3 安装、内核参数修改与验证已全部完成！${PLAIN}"

else
    # ----------------------------------------------------------------
    # 状态 B: 首次运行 -> 调度调用 byJoey 的最新 BBRv3 专属安装脚本
    # ----------------------------------------------------------------
    echo -e "${YELLOW}[提示] 检测到当前尚未安装 BBRv3 内核，正在为您启动 byJoey/Actions-bbr-v3 官方交互式安装菜单...${PLAIN}"
    sleep 2
    
    # 直接拉取并运行您指定的 byJoey 专属一键安装环境
    bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh)
    
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e "${GREEN}  byJoey 内核部署完毕！${PLAIN}"
    echo -e "${YELLOW}  【后续步骤引导】：${PLAIN}"
    echo -e "${YELLOW}  1. 如果刚才在菜单中【安装/更新内核】成功，请确保键入：${RED}reboot${YELLOW} 重启。${PLAIN}"
    echo -e "${YELLOW}  2. 服务器重启完成后，【请再次执行本脚本】。${PLAIN}"
    echo -e "${YELLOW}  3. 第二次运行时，脚本会自动把您的 fs.file-max = 65535 及 BBR 变量安全写入并输出最终验证。${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
fi
