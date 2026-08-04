#!/usr/bin/env bash

# 强制重定向输入终端，确保 curl | bash 模式下交互正常
if [ -t 0 ]; then :; else exec </dev/tty; fi

# ================= 终极安全沙箱初始化 =================
TMP_DIR=$(mktemp -d /tmp/yw_box.XXXXXX)
if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
    echo "❌ 致命错误：安全沙箱创建失败，脚本终止。"; exit 1
fi
chmod 700 "$TMP_DIR"

trap 'rm -rf "$TMP_DIR" 2>/dev/null' EXIT
trap 'rm -rf "$TMP_DIR" 2>/dev/null; exit 130' INT
trap 'rm -rf "$TMP_DIR" 2>/dev/null; exit 143' TERM

# ================= 全局变量与颜色定义 =================
: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[36m}" "${gh_proxy:=https://}"
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"

DEBUG=${DEBUG:-0}
log_debug() { [ "$DEBUG" = "1" ] && echo -e "${H}[DEBUG] $1${R}" >&2; }

send_stats() { :; return 0; }
root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    root_use
    local need_update=0
    for cmd in curl wget jq openssl iptables tar ip ss free modprobe ethtool; do
        command -v $cmd >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget jq openssl iptables tar ca-certificates iproute2 procps kmod ethtool >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum update -y >/dev/null 2>&1
            yum install -y curl wget jq openssl iptables tar ca-certificates iproute procps-ng kmod ethtool >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            apk add curl wget jq openssl iptables tar ca-certificates iproute2 procps kmod ethtool >/dev/null 2>&1
        fi
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
}

# ================= 基础工具函数 =================
check_swap() {
    local swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -ge 512 ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    
    if command -v lsblk >/dev/null 2>&1; then
        local is_slow_disk=$(lsblk -d -o ROTA,NAME | awk '$1==1{print $2}')
        if [ -n "$is_slow_disk" ]; then
            echo -e "${Y}检测到普通云盘，跳过 Swapfile 创建（防止 IO 阻塞），自动启用 ZRAM...${R}"
            auto_setup_zram; return 0
        fi
    fi

    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then 
        swapon /swapfile >/dev/null 2>&1
        swap_total=$(free -m | awk '/Swap/{print $2}')
        [ "$swap_total" -ge 512 ] && return 0
    fi
    
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${Y}创建 512MB Swap...${R}"
        if dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null && \
           chmod 600 /swapfile && \
           mkswap /swapfile >/dev/null 2>&1 && \
           swapon /swapfile >/dev/null 2>&1; then
            grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
            echo -e "${G}✅ Swap 完成。${R}"
        else
            echo -e "${RED}❌ Swap 创建失败，请检查磁盘空间是否充足！${R}"
            rm -f /swapfile 2>/dev/null
        fi
    fi
}
auto_setup_zram() {
    if grep -qaE "lxc|docker|containerd" /proc/1/environ 2>/dev/null || [ -f /.dockerenv ] || ! lsmod | grep -q zram; then
        if ! modprobe zram 2>/dev/null; then
            echo -e "${Y}检测到当前虚拟化架构不支持 ZRAM 内核模块，跳过配置。${R}"
            return 1
        fi
    fi
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if ! command -v zramctl >/dev/null 2>&1; then apt-get install -y zram-tools >/dev/null 2>&1 || return 1; fi
    
    mkdir -p /etc/default
    echo -e "ALGO=zstd\nPERCENT=50" > /etc/default/zramswap
    systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1
}
check_disk_space() { local available_mb=$(df -m / | tail -1 | awk '{print $4}'); [ "$available_mb" -lt "$1" ] && { echo -e "${RED}磁盘不足${R}"; return 1; }; return 0; }
server_reboot() { read -e -p "是否现在重启？: " c; [[ "$c" =~ ^[Yy]$ ]] && reboot; }
bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then if ! grep -q "tcp_congestion_control = bbr" "$CONF" 2>/dev/null; then sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"; echo "net.ipv4.tcp_congestion_control = bbr" >> "$CONF"; fi; sysctl -p "$CONF" >/dev/null 2>&1; fi
}

_optimize_nic_queues() {
    local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$main_nic" ] && return
    local cpu_count=$(nproc)
    [ "$cpu_count" -le 1 ] && return
    
    local mask="" full_cores=$((cpu_count / 8)) remainder=$((cpu_count % 8))
    for i in $(seq 1 $full_cores); do mask="${mask}ff"; done
    if [ $remainder -gt 0 ]; then
        local rem_val=$(( (1 << remainder) - 1 ))
        mask="${mask}$(printf '%02x' $rem_val)"
    fi
    [ -z "$mask" ] && return

    for q in /sys/class/net/$main_nic/queues/rx-*; do
        [ -f "$q/rps_cpus" ] && [ -w "$q/rps_cpus" ] && echo $mask > "$q/rps_cpus" 2>/dev/null
        [ -f "$q/rps_flow_cnt" ] && [ -w "$q/rps_flow_cnt" ] && echo 32768 > "$q/rps_flow_cnt" 2>/dev/null
    done
    for q in /sys/class/net/$main_nic/queues/tx-*; do
        [ -f "$q/xps_cpus" ] && [ -w "$q/xps_cpus" ] && echo $mask > "$q/xps_cpus" 2>/dev/null
    done
}

get_current_opt_mode() {
    if [ -f /etc/sysctl.d/99-yw-optimize.conf ]; then
        grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | tr -d ' \t'
    elif [ -f /etc/sysctl.d/99-smart.conf ]; then echo "智能自动优化"
    else echo "系统默认(未优化)"
    fi
}

# ================= 内核与网络深度优化 (极简安全版) =================
_kernel_optimize_core() {
    local mode_name="$1" CONF="/etc/sysctl.d/99-yw-optimize.conf"
    
    rm -f /etc/sysctl.d/99-tiktok-live.conf /etc/sysctl.d/99-smart.conf /etc/sysctl.d/99-tiktok-udp.conf /etc/sysctl.d/99-bandwidth.conf /etc/sysctl.d/99-lowprofile-optimize.conf 2>/dev/null || true
    
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
    cat > "$CONF" << EOF
# 模式: ${mode_name}|极简稳定版
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 1048576
fs.nr_open = 1048576
EOF
    local err=$(sysctl -p "$CONF" 2>&1 | grep -cE "Invalid|No such|unknown key" 2>/dev/null) || err=0
    echo -e "${G}应用完成，跳过 ${err} 项不支持参数${R}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then echo -e "\n# YW-optimize\n* soft nofile 1048576\n* hard nofile 1048576" >> /etc/security/limits.conf; fi
    ulimit -n 1048576 2>/dev/null; check_swap >/dev/null 2>&1
    _optimize_nic_queues
    echo -e "${G}${mode_name} 完成！已启用极简安全 BBR 模式。${R}"; read -rs -n 1 -p ""
}

# ================= 智能自动优化 =================
smart_auto_optimize() {
    clear
    echo -e "${G}╔═══════════════════════════════════════════╗${R}"
    echo -e "${G}║      🚀 智能自动优化 (推荐新手)            ║${R}"
    echo -e "${G}╚═══════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${Y}即将应用安全稳定的网络优化参数 (BBR+fq)...${R}"
    sleep 1
    if prompt_yes_no "开始优化？(推荐直接回车) " "y"; then
        echo ""
        _kernel_optimize_core "智能自动优化"
        echo -e "${G}✅ 优化完成！${R}"
        echo -e "${Y}建议重启服务器获得最佳效果${R}"
        if prompt_yes_no "是否现在重启？" "n"; then
            reboot
        fi
        read -rs -n 1 -p "按任意键继续..."
    fi
}

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal buster releases" | grep -qw "$os_codename"; then echo -e "${RED}XanMod 已停止支持${R}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    if ! wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; then
        echo -e "${RED}❌ XanMod 密钥下载/转换失败！${R}"
        rm -f "$keyring"
        return 1
    fi
    [ ! -s "$keyring" ] && { echo -e "${RED}❌ 密钥文件为空${R}"; return 1; }
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local arch=$(uname -m)
    if [ "$arch" = "aarch64" ]; then
        apt update -y >/dev/null 2>&1
        if apt-cache policy "linux-xanmod-arm64" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
            printf '%s\n' "linux-xanmod-arm64"; return 0
        fi
        return 1
    fi
    local psabi_level=$(awk -F: '/^flags/{ if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit} }' /proc/cpuinfo 2>/dev/null)
    if [ -z "$psabi_level" ]; then return 1; fi
    [ "$psabi_level" -gt 3 ] && psabi_level=3
    apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do local l="$psabi_level"; while [ "$l" -ge 1 ]; do local p="${prefix}-x64v${l}"; if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [0-9]'; then printf '%s\n' "$p"; return 0; fi; l=$((l-1)); done; done
    return 1
}
bbrv3() {
    root_use
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do clear; echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"; read -e -p "选择: " c
        case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; 0|"") break ;; *) break ;; esac; done
    else clear; echo "设置BBR3"; read -e -p "继续？: " c; [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot; fi
}
restore_defaults() {
    clear
    echo -e "${Y}正在还原所有网络与内核优化设置...${R}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf /etc/sysctl.d/99-smart.conf /etc/sysctl.d/99-tiktok-live.conf /etc/sysctl.d/99-tiktok-udp.conf /etc/sysctl.d/99-bandwidth.conf /etc/sysctl.d/99-lowprofile-optimize.conf /etc/sysctl.d/99-lowmemory-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
    sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    systemctl is-enabled zramswap >/dev/null 2>&1 && { systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; }
    echo -e "${G}✅ 已还原所有设置至系统初始状态！${R}"
    read -rs -n 1 -p "按任意键继续..."
}
verify_network_status() {
    clear; local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null) mode="未知"
    case $rmem in
        8388608) sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null | grep -q "300" && mode="中转网关" || mode="电竞游戏" ;;
        16777216) mode="通用/中等" ;; 33554432) mode="2-4G折中" ;; 4194304) mode="极限低内存" ;;
        67108864|134217728) sysctl -n net.core.netdev_budget 2>/dev/null | grep -q "1200" && { sysctl -n net.core.optmem_max 2>/dev/null | grep -q "40960" && mode="直播+游戏混合★" || mode="纯直播"; } || { sysctl -n vm.dirty_ratio 2>/dev/null | grep -q "40" && mode="高性能下载" || mode="高并发网站"; } ;;
    esac
    echo -e "${Y}算法: $(sysctl -n net.ipv4.tcp_congestion_control) | 队列: $(sysctl -n net.core.default_qdisc) | 缓冲: $((rmem/1024/1024))MB\n鉴定结果: ${G}${mode}${R}"; read -rs -n 1 -p ""
}

show_sys_info() {
    while true; do
        local cpu_info=$(lscpu 2>/dev/null | awk -F':' '/Model name:/ {print $2}' | sed 's/^[ \t]*//')
        local cpu_usage_percent=$(awk 'NR==1{u1=$2+$4; t1=$2+$3+$4+$5+$6+$7+$8} NR==2{u2=$2+$4; t2=$2+$3+$4+$5+$6+$7+$8; printf "%.0f\n", (1 - (u2-u1)/(t2-t1)) * 100}' <(head -1 /proc/stat) <(sleep 1; head -1 /proc/stat))
        local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
        local cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')
        local mem_total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_used_mb=$((mem_total_mb - mem_avail_mb))
        local mem_percent=$(awk "BEGIN{printf \"%.1f\", ${mem_used_mb}*100/(${mem_total_mb}+0.001)}")
        local mem_info="${mem_avail_mb}M/${mem_total_mb}M (${mem_percent}%)"
        local disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
        echo -ne "${H}正在获取外网IP信息...${R}\r"
        local ipinfo=$(curl -s --connect-timeout 2 --max-time 3 https://api.ipify.org 2>/dev/null || echo "{}")
        if [ -n "$ipinfo" ] && [ "$ipinfo" != "{}" ]; then
            local geo_info=$(curl -s --connect-timeout 2 --max-time 3 "http://ip-api.com/json/${ipinfo}?fields=country,city,isp" 2>/dev/null || echo "{}")
            local country=$(echo "$geo_info" | jq -r '.country // empty' 2>/dev/null)
            local city=$(echo "$geo_info" | jq -r '.city // empty' 2>/dev/null)
            local isp_info=$(echo "$geo_info" | jq -r '.isp // empty' 2>/dev/null)
        fi
        local load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
        local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2 } END {print ""}' /etc/resolv.conf)
        local cpu_arch=$(uname -m)
        local hostname_val=$(uname -n)
        local kernel_version=$(uname -r)
        local congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        local os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')
        local current_time=$(date "+%Y-%m-%d %I:%M %p")
        local swap_total_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local swap_avail_mb=$(awk '/SwapFree/{printf "%d", $2/1024}' /proc/meminfo)
        local swap_used_mb=$((swap_total_mb - swap_avail_mb))
        local swap_percent="0%"
        [ "$swap_total_mb" -gt 0 ] && swap_percent=$(awk "BEGIN{printf \"%d%%\", ${swap_used_mb}*100/${swap_total_mb}}")
        local swap_info="${swap_used_mb}M/${swap_total_mb}M (${swap_percent}%)"
        local runtime=$(cat /proc/uptime 2>/dev/null | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')
        local tcp_count=$(ss -tn state established 2>/dev/null | wc -l)
        local udp_count=$(ss -un state established 2>/dev/null | wc -l)
        local rx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$2} END{print a+0}' /proc/net/dev)
        local tx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$10} END{print a+0}' /proc/net/dev)
        local rx_gb=$(awk "BEGIN{printf \"%.2f\", ${rx}/1024/1024/1024}")
        local tx_gb=$(awk "BEGIN{printf \"%.2f\", ${tx}/1024/1024/1024}")
        local ipv4_addr=$(ip -4 addr 2>/dev/null | grep inet | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        local ipv6_addr=$(ip -6 addr 2>/dev/null | grep inet6 | grep -v "::1" | awk '{print $2}' | head -1)
        clear
        echo -e "${C}系统信息查询${R}"
        echo -e "${C}=============="
        echo -e "${C}主机名:         ${R}${hostname_val}"
        echo -e "${C}系统版本:       ${R}${os_info}"
        echo -e "${C}Linux版本:      ${R}${kernel_version}"
        echo -e "${C}=============="
        echo -e "${C}CPU架构:        ${R}${cpu_arch}"
        echo -e "${C}CPU型号:        ${R}${cpu_info}"
        echo -e "${C}CPU核心数:      ${R}${cpu_cores}"
        echo -e "${C}CPU频率:        ${R}${cpu_freq}"
        echo -e "${C}=============="
        echo -e "${C}CPU占用:        ${R}${cpu_usage_percent}%"
        echo -e "${C}系统负载:       ${R}${load}"
        echo -e "${C}TCP|UDP连接数:  ${R}${tcp_count}|${udp_count}"
        echo -e "${C}物理内存:       ${R}${mem_info}"
        echo -e "${C}虚拟内存:       ${R}${swap_info}"
        echo -e "${C}硬盘占用:       ${R}${disk_info}"
        echo -e "${C}=============="
        echo -e "${C}总接收:         ${R}${rx_gb}G"
        echo -e "${C}总发送:         ${R}${tx_gb}G"
        echo -e "${C}=============="
        echo -e "${C}网络算法:       ${R}${congestion_algorithm:-N/A} ${queue_algorithm:-N/A}"
        echo -e "${C}=============="
        echo -e "${C}运营商:         ${R}${isp_info}"
        [ -n "${ipv4_addr}" ] && echo -e "${C}IPv4地址:       ${R}${ipv4_addr}"
        [ -n "${ipv6_addr}" ] && echo -e "${C}IPv6地址:       ${R}${ipv6_addr}"
        echo -e "${C}DNS地址:        ${R}${dns_addresses}"
        echo -e "${C}地理位置:       ${R}${country} ${city}"
        echo -e "${C}系统时间:       ${R}${current_time}"
        echo -e "${C}=============="
        echo -e "${C}运行时长:       ${R}${runtime}"
        echo -e "${Y}==============\n0. 返回主菜单${R}"
        read -e -p "请输入选择: " menu_choice
        case "$menu_choice" in 0|"") break ;; esac
    done
}

Kernel_optimize() {
    root_use
    while true; do
        clear
        local current_mode=$(get_current_opt_mode)
        echo -e "${G}╔═══════════════════════════════════╗"
        echo -e "║       Linux 内核网络优化 (安全版)   ║"
        echo -e "╚═══════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${C}当前网络状态: ${Y}${current_mode}${R}"
        echo ""
        echo -e "    ${Y}[1] 智能自动优化 (推荐，仅开 BBR)${R}"
        echo -e "    ${H}[2] BBRv3 (XanMod内核)${R}"
        echo -e "    ${H}[3] ⚠️ 一键还原系统默认设置${R}"
        echo -e "    ${H}[4] 释放缓存  [5] 验证状态  [0] 返回${R}"
        echo ""
        read -e -p "  选择: " c
        case $c in
            1) clear; smart_auto_optimize ;;
            2) clear; bbrv3 ;;
            3) clear; restore_defaults ;;
            4) read -e -p "确定释放缓存？: " d; [[ "$d" =~ ^[Yy]$ ]] && sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null ;;
            5) verify_network_status ;; 0|"") break ;;
        esac
    done
}

# ================= Sing-Box 管理 (转接甬哥脚本) =================
sb_menu() {
    clear
    echo -e "${G}╔═══════════════════════════════════════════╗${R}"
    echo -e "${G}║       Sing-Box 管理 (转接至甬哥脚本)      ║${R}"
    echo -e "${G}╚═══════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${Y}即将启动甬哥 (yonggekkk) 的 Sing-box 精装桶脚本。${R}"
    echo -e "${Y}该脚本功能最全、兼容性最好，支持四协议共存及全平台订阅。${R}"
    echo -e "${H}请在甬哥脚本中完成节点的添加和管理。${R}"
    echo ""
    read -e -p "按回车键继续，或按 Ctrl+C 取消: " confirm
    if command -v curl >/dev/null 2>&1; then
        bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
    elif command -v wget >/dev/null 2>&1; then
        bash <(wget -qO- https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)
    else
        echo -e "${RED}错误: 需要 curl 或 wget 来下载脚本。${R}"
    fi
    read -rs -n 1 -p "按任意键返回主菜单..."
}

# ================= 优化中心菜单 =================
optimization_center_menu() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗"
        echo -e "║           🚀 优化中心 (安全稳定版)          ║"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}⚠️  提示: 选下面其中一个即可，重复优化会互相覆盖${R}"
        echo ""
        echo -e "    ${C}【 落地机优化 】${R}"
        echo -e "    ${G}[1] 智能自动优化 (推荐，适合99%用户)${R}"
        echo -e "        自动检测系统 + 安全网络优化 (BBR+fq)"
        echo -e "    ${H}[2] Linux内核网络优化${R}"
        echo -e "    ${H}[3] BBRv3 (XanMod内核)${R}"
        echo -e "    ${H}[4] ⚠️ 一键还原系统默认设置${R}"
        echo -e "    ${H}[5] 验证网络状态  [0] 返回主菜单${R}"
        echo ""
        read -e -p "  请选择: " c
        case "$c" in
            1) clear; smart_auto_optimize ;;
            2) clear; Kernel_optimize ;;
            3) clear; bbrv3 ;;
            4) clear; restore_defaults ;;
            5) clear; verify_network_status ;;
            0|"") break ;;
            *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

# ================= 主菜单 =================
main_menu() {
    check_env
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗"
        echo -e "║          🎉 YW 服务器优化工具箱             ║"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}[1] 📊 系统信息查询${R}"
        echo ""
        echo -e "    ${Y}[2] 🚀 优化中心（推荐）${R}"
        echo -e "    ${H}   - 内核网络优化 (BBR+fq)${R}"
        echo ""
        echo -e "    ${Y}[3] 📦 Sing-Box 管理面板${R}"
        echo -e "    ${H}   - 转接至甬哥 sing-box-yg 脚本${R}"
        echo ""
        echo -e "    ${H}[0] 退出${R}"
        echo ""
        read -e -p "  请选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; show_sys_info ;;
            2) clear; optimization_center_menu ;;
            3) clear; sb_menu ;;
            0|"") echo -e "${G}再见！${R}"; exit 0 ;; *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

main_menu
