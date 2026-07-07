#!/usr/bin/env bash
: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_hong:=\033[31m}" "${gl_kjlan:=\033[32m}" "${gh_proxy:=https://}"
send_stats() { :; return 0; }
root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${gl_red}错误：请使用 root 用户运行此脚本${gl_bai}"; exit 1; }; }
check_env() {
    local need_update=0
    if ! command -v curl >/dev/null 2>&1; then echo -e "${gl_huang}安装 curl...${gl_bai}"; need_update=1; fi
    if ! command -v jq >/dev/null 2>&1; then echo -e "${gl_huang}安装 jq...${gl_bai}"; need_update=1; fi
    if ! command -v openssl >/dev/null 2>&1; then echo -e "${gl_huang}安装 openssl...${gl_bai}"; need_update=1; fi
    if [ "$need_update" -eq 1 ]; then
        if command -v apt >/dev/null 2>&1; then apt-get update -y >/dev/null 2>&1; apt-get install -y curl jq openssl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then yum install -y curl jq openssl >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add curl jq openssl >/dev/null 2>&1; fi
        echo -e "${gl_lv}✅ 依赖准备完毕！${gl_bai}"; fi
}
check_swap() {
    local swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -ge 512 ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then swapon /swapfile >/dev/null 2>&1; swap_total=$(free -m | awk '/Swap/{print $2}'); [ "$swap_total" -ge 512 ] && return 0; fi
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${gl_huang}创建 512MB Swap...${gl_bai}"; dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null; chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo -e "${gl_lv}✅ Swap 完成。${gl_bai}"; fi
}
auto_setup_zram() {
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then apt-get install -y zram-tools >/dev/null 2>&1 || return 1; fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null; sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1; fi
}
check_disk_space() { local available_mb=$(df -m / | tail -1 | awk '{print $4}'); [ "$available_mb" -lt "$1" ] && { echo -e "${gl_red}磁盘不足${gl_bai}"; return 1; }; return 0; }
install_pkg() {
    if command -v apt >/dev/null 2>&1; then apt-get install -y "$@" >/tmp/yw_apt.log 2>&1 || { echo -e "${gl_red}APT失败${gl_bai}"; return 1; }
    elif command -v yum >/dev/null 2>&1; then yum install -y "$@" >/tmp/yw_yum.log 2>/dev/null || { echo -e "${gl_red}YUM失败${gl_bai}"; return 1; }; fi; return 0
}
server_reboot() { read -e -p "是否现在重启？: " c; [[ "$c" =~ ^[Yy]$ ]] && reboot; }
bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then if ! grep -q "tcp_congestion_control = bbr" "$CONF" 2>/dev/null; then sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"; echo "net.ipv4.tcp_congestion_control = bbr" >> "$CONF"; fi; sysctl -p "$CONF" >/dev/null 2>&1; fi
}
change_swap_size() {
    local swap_file="/swapfile" current_swap=$(free -m | awk '/Swap/{print $2}')
    clear; echo -e "${gl_huang}======== Swap 管理 ========\n当前: ${gl_lv}${current_swap} MB${gl_bai}\n1.1G 2.2G 3.4G 4.6G 5.自定义 6.移除 0.返回"
    read -e -p "选择: " c; local s=""
    case $c in 1) s=1024;; 2) s=2048;; 3) s=4096;; 4) s=6144;; 5) read -e -p "大小(MB): " s; [[ ! "$s" =~ ^[0-9]+$ ]] && return;; 6) swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '/swapfile/d' /etc/fstab; return;; 0|"") return;; esac
    [ -z "$s" ] && return
    swapoff "$swap_file" 2>/dev/null; dd if=/dev/zero of="$swap_file" bs=1M count=$s 2>/dev/null; chmod 600 "$swap_file"; mkswap "$swap_file" >/dev/null 2>&1; swapon "$swap_file" >/dev/null 2>&1
    grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo -e "${gl_lv}✅ 完成${gl_bai}"; read -rs -n 1 -p ""
}
_kernel_optimize_core() {
    local mode_name="$1" scene="${2:-stream_game}" CONF="/etc/sysctl.d/99-yw-optimize.conf"
    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES CC="bbr" QDISC="fq" UDP_RMEM_MIN=131072 TCP_NOTSENT_LOWAT=16384 TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1 HIGH_EXTRA="" STREAM_EXTRA="" GAME_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA="" STREAM_GAME_EXTRA="" TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0 CONNTRACK_MULT=32
    case "$scene" in
        stream_game) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=8; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000\nnet.core.optmem_max = 40960' ;;
        high) SWAPPINESS=10; OVERCOMMIT=1; VFS_PRESSURE=50; DIRTY_RATIO=40; DIRTY_BG_RATIO=10; MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; HIGH_EXTRA=$'vm.dirty_ratio = 40\nvm.dirty_background_ratio = 10' ;;
        web) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15; KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3; WEB_EXTRA=$'net.ipv4.tcp_max_tw_buckets = 524288\nnet.ipv4.tcp_max_syn_backlog = 16384' ;;
        stream) SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; STREAM_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000' ;;
        game) SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=8388608; WMEM_MAX=8388608; TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480' ;;
        gateway) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=32768; RMEM_MAX=8388608; WMEM_MAX=8388608; TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"; SOMAXCONN=65535; BACKLOG=100000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=30; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=16384; GATEWAY_EXTRA=$'net.core.optmem_max = 20480' ;;
        balanced) SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75; MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"; SCHED_AUTOGROUP=0; THP="always"; NUMA=1; FIN_TIMEOUT=30; KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5; TCP_SLOW_START_AFTER_IDLE=1; BALANCED_EXTRA="vm.overcommit_memory = 0" ;;
    esac
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0) HAS_SWAP=$(free -m | awk '/Swap/{print $2}')
    if [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 2048 ]; then MIN_FREE_KB=65536; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; BACKLOG=50000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 65536\nnet.ipv4.udp_wmem_min = 65536\nnet.ipv4.udp_rmem_max = 8388608\nnet.ipv4.udp_wmem_max = 8388608\nnet.core.netdev_budget = 800\nnet.core.netdev_max_backlog = 50000\nnet.core.optmem_max = 20480'
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; BACKLOG=10000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 10000\nnet.core.optmem_max = 20480'
    else MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"; HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""; STREAM_GAME_EXTRA=""; [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; check_swap; auto_setup_zram; fi
    local KVER=$(uname -r | grep -oP '^\d+\.\d+'); CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then modprobe tcp_bbr 2>/dev/null; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && { CC="bbr"; QDISC="fq"; }; fi
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ] && [ "$MEM_MB_VAL" -ge 1024 ] && STREAM_GAME_EXTRA="${STREAM_GAME_EXTRA:-${STREAM_EXTRA}}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288; [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
    cat > "$CONF" << EOF
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.udp_rmem_min = $UDP_RMEM_MIN
net.ipv4.udp_wmem_min = $UDP_RMEM_MIN
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.ipv4.tcp_fastopen = $TCP_FASTOPEN
net.ipv4.tcp_tw_reuse = $TCP_TW_REUSE
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = $TW_BUCKETS
net.ipv4.tcp_max_orphans = $MAX_ORPHANS
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = $TCP_MTU_PROBING
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = $TCP_NOTSENT_LOWAT
net.ipv4.tcp_slow_start_after_idle = $TCP_SLOW_START_AFTER_IDLE
net.ipv4.tcp_ecn = $TCP_ECN
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_DEF $TCP_MEM_MAX
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
 $( [ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa不支持" )
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
fs.file-max = 1048576
fs.nr_open = 1048576
 $( if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * CONNTRACK_MULT))"; echo "net.netfilter.nf_conntrack_tcp_timeout_established = 1800"; echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15"; echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10"; echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10"; else echo "# conntrack未启用"; fi )
 $HIGH_EXTRA
 $WEB_EXTRA
 $STREAM_EXTRA
 $GAME_EXTRA
 $BALANCED_EXTRA
 $GATEWAY_EXTRA
 $STREAM_GAME_EXTRA
EOF
    local err=$(sysctl -p "$CONF" 2>&1 | grep -cE "Invalid|No such|unknown key" 2>/dev/null) || err=0
    echo -e "${gl_lv}应用完成，跳过 ${err} 项不支持参数${gl_bai}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then echo -e "\n# YW-optimize\n* soft nofile 1048576\n* hard nofile 1048576" >> /etc/security/limits.conf; fi
    ulimit -n 1048576 2>/dev/null; check_swap >/dev/null 2>&1; bbr_on
    echo -e "${gl_lv}${mode_name} 完成！内存: ${MEM_MB_VAL}MB | 算法: ${CC}${gl_bai}"; read -rs -n 1 -p ""
}
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then echo -e "${gl_hong}XanMod 已停止支持${gl_bai}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    install_pkg wget gnupg ca-certificates || return 1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}
xanmod_detect_package() {
    local psabi_level=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit}}' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3; apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do local l="$psabi_level"; while [ "$l" -ge 1 ]; do local p="${prefix}-x64v${l}"; if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^ ]'; then printf '%s\n' "$p"; return 0; fi; l=$((l-1)); done; done; return 1
}
bbrv3() {
    root_use
    if [ "$(uname -m)" = "aarch64" ]; then bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return 0; fi
    if [ -r /etc/os-release ]; then . /etc/os-release; if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then echo "仅支持Debian/Ubuntu"; return 0; fi; else return 0; fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do clear; echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"; read -e -p "选择: " c
        case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; *) break ;; esac; done
    else clear; echo "设置BBR3"; read -e -p "继续？: " c; [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot; fi
}
restore_defaults() {
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    systemctl is-enabled zramswap >/dev/null 2>&1 && { systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; }
    echo -e "${gl_lv}已还原所有设置${gl_bai}"; read -rs -n 1 -p ""
}
verify_network_status() {
    clear; local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null) mode="未知"
    case $rmem in
        8388608) sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null | grep -q "300" && mode="中转网关" || mode="电竞游戏" ;;
        16777216) mode="通用/中等" ;; 33554432) mode="2-4G折中" ;; 4194304) mode="极限低内存" ;;
        67108864|134217728) sysctl -n net.core.netdev_budget 2>/dev/null | grep -q "1200" && { sysctl -n net.core.optmem_max 2>/dev/null | grep -q "40960" && mode="直播+游戏混合★" || mode="纯直播"; } || { sysctl -n vm.dirty_ratio 2>/dev/null | grep -q "40" && mode="高性能下载" || mode="高并发网站"; } ;;
    esac
    echo -e "${gl_huang}算法: $(sysctl -n net.ipv4.tcp_congestion_control) | 队列: $(sysctl -n net.core.default_qdisc) | 缓冲: $((rmem/1024/1024))MB\n鉴定结果: ${gl_lv}${mode}${gl_bai}"; read -rs -n 1 -p ""
}
show_sys_info() {
    while true; do
        send_stats "系统信息查询"
        local cpu_info=$(lscpu 2>/dev/null | awk -F':' '/Model name:/ {print $2}' | sed 's/^[ \t]*//')
        local cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))
        local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
        local cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')
        local mem_total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_used_mb=$((mem_total_mb - mem_avail_mb))
        local mem_percent=$(awk "BEGIN{printf \"%.1f\", ${mem_used_mb}*100/${mem_total_mb}}")
        local mem_info="${mem_avail_mb}M/${mem_total_mb}M (${mem_percent}%)"
        local disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
        echo -ne "${gl_hui}正在获取外网IP信息(超时3秒自动跳过)...${gl_bai}\r"
        local ipinfo=$(curl -s --connect-timeout 2 --max-time 3 ipinfo.io 2>/dev/null || echo "{}")
        local country=$(echo "$ipinfo" | jq -r '.country // empty' 2>/dev/null)
        local city=$(echo "$ipinfo" | jq -r '.city // empty' 2>/dev/null)
        local isp_info=$(echo "$ipinfo" | jq -r '.org // empty' 2>/dev/null)
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
        local timezone=$(cat /etc/timezone 2>/dev/null || echo "Unknown")
        local tcp_count=$(ss -t state established 2>/dev/null | wc -l)
        local udp_count=$(ss -u state established 2>/dev/null | wc -l)
        local rx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$2} END{print a+0}' /proc/net/dev)
        local tx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$10} END{print a+0}' /proc/net/dev)
        local rx_gb=$(awk "BEGIN{printf \"%.2f\", ${rx}/1024/1024/1024}")
        local tx_gb=$(awk "BEGIN{printf \"%.2f\", ${tx}/1024/1024/1024}")
        local ipv4_addr=$(ip -4 addr 2>/dev/null | grep inet | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        local ipv6_addr=$(ip -6 addr 2>/dev/null | grep inet6 | grep -v "::1" | awk '{print $2}' | head -1)
        clear
        echo -e "${gl_kjlan}系统信息查询${gl_bai}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}主机名:         ${gl_bai}${hostname_val}"
        echo -e "${gl_kjlan}系统版本:       ${gl_bai}${os_info}"
        echo -e "${gl_kjlan}Linux版本:      ${gl_bai}${kernel_version}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}CPU架构:        ${gl_bai}${cpu_arch}"
        echo -e "${gl_kjlan}CPU型号:        ${gl_bai}${cpu_info}"
        echo -e "${gl_kjlan}CPU核心数:      ${gl_bai}${cpu_cores}"
        echo -e "${gl_kjlan}CPU频率:        ${gl_bai}${cpu_freq}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}CPU占用:        ${gl_bai}${cpu_usage_percent}%"
        echo -e "${gl_kjlan}系统负载:       ${gl_bai}${load}"
        echo -e "${gl_kjlan}TCP|UDP连接数:  ${gl_bai}${tcp_count}|${udp_count}"
        echo -e "${gl_kjlan}物理内存:       ${gl_bai}${mem_info}"
        echo -e "${gl_kjlan}虚拟内存:       ${gl_bai}${swap_info}"
        echo -e "${gl_kjlan}硬盘占用:       ${gl_bai}${disk_info}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}总接收:         ${gl_bai}${rx_gb}G"
        echo -e "${gl_kjlan}总发送:         ${gl_bai}${tx_gb}G"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}网络算法:       ${gl_bai}${congestion_algorithm:-N/A} ${queue_algorithm:-N/A}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}运营商:         ${gl_bai}${isp_info}"
        [ -n "${ipv4_addr}" ] && echo -e "${gl_kjlan}IPv4地址:       ${gl_bai}${ipv4_addr}"
        [ -n "${ipv6_addr}" ] && echo -e "${gl_kjlan}IPv6地址:       ${gl_bai}${ipv6_addr}"
        echo -e "${gl_kjlan}DNS地址:        ${gl_bai}${dns_addresses}"
        echo -e "${gl_kjlan}地理位置:       ${gl_bai}${country} ${city}"
        echo -e "${gl_kjlan}系统时间:       ${gl_bai}${timezone} ${current_time}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_kjlan}运行时长:       ${gl_bai}${runtime}"
        echo -e "${gl_kjlan}=============="
        echo -e "${gl_huang}0. 返回主菜单"
        echo -e "${gl_huang}=============="
        read -e -p "请输入选择: " menu_choice
        case "$menu_choice" in 0|"") break ;; *) break ;; esac
    done
    return 0
}
Kernel_optimize() {
    root_use
    while true; do clear; local cur="未优化"; [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        echo -e "${gl_lv}Linux内核优化 | 当前: ${gl_huang}${cur}${gl_bai}\n
        1.直播+游戏 
        2.高性能 
        3.均衡 
        4.网站 
        5.纯直播 
        6.纯游戏 
        7.中转网关
        8.还原默认 
        9.远程脚本 
        10.释放缓存 
        11.验证状态\n0.返回"
        read -e -p "选择: " c
        case $c in 1) clear; _kernel_optimize_core "直播+游戏" "stream_game" ;; 2) clear; _kernel_optimize_core "高性能" "high" ;; 3) clear; _kernel_optimize_core "均衡" "balanced" ;; 4) clear; _kernel_optimize_core "网站" "web" ;; 5) clear; _kernel_optimize_core "直播" "stream" ;; 6) clear; _kernel_optimize_core "游戏" "game" ;; 7) clear; _kernel_optimize_core "网关" "gateway" ;; 8) clear; restore_defaults ;; 9) curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;; 10) read -e -p "确定释放缓存？: " d; [[ "$d" =~ ^[Yy]$ ]] && sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null ;; 11) verify_network_status ;; 0|"") break ;; esac; done
}
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="\033[36m"
get_my_ip() { curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || echo "未知IP"; }
url_encode() { printf '%s' "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/@/%40/g'; }
_test_tls_once() {
    local host="$1" t1 t2 ms
    t1=$(date +%s%3N 2>/dev/null)
    [[ ! "$t1" =~ ^[0-9]+$ ]] && t1=$(date +%s)000
    if timeout 2 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
        t2=$(date +%s%3N 2>/dev/null)
        [[ ! "$t2" =~ ^[0-9]+$ ]] && t2=$(date +%s)000
        ms=$((t2 - t1))
        [ "$ms" -ge 0 ] 2>/dev/null && echo "$ms" || echo "9999"
    else
        echo "9999"
    fi
}
select_sni() {
    echo -e "${Y}1.默认 2.优选 3.手动${R}" >&2; read -e -p "SNI选择: " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2) local d=("azure.microsoft.com" "bing.com" "www.icloud.com" "www.microsoft.com" "xp.apple.com" "www.xbox.com" "snap.licdn.com" "www.oracle.com" "speed.cloudflare.com") f="/tmp/sb_sni.$$"; : > "$f"
        for i in "${d[@]}"; do local ms; ms=$(_test_tls_once "$i"); echo "${ms} ${i}" >> "$f"; done
        local b_d="www.microsoft.com" b_t=9999; while IFS=' ' read -r t dom; do [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null && { b_t=$t; b_d="$dom"; }; done < <(sort -n "$f" | head -1)
        rm -f "$f"; echo -e "${G}优选: ${b_d} (${b_t}ms)${R}" >&2; echo "$b_d" ;;
        3) read -e -p "域名: " s; echo "${s:-www.microsoft.com}" ;; *) echo "www.microsoft.com" ;;
    esac
}
sb_check() { if ! command -v sing-box >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box${R}"; return 1; fi; if ! command -v jq >/dev/null 2>&1; then echo -e "${RED}请先安装 jq${R}"; return 1; fi; return 0; }
sb_init_conf() { local conf="/etc/sing-box/config.json"; if [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then mkdir -p /etc/sing-box; echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"; fi; }
META_FILE="/etc/sing-box/.nodes_meta"
_init_meta_file() { [ ! -f "$META_FILE" ] || ! jq -e . "$META_FILE" >/dev/null 2>&1 && { mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"; }; }
_save_node_meta() { _init_meta_file; if [ -n "$4" ]; then jq --arg p "$1" --arg n "$2" --arg t "$3" --arg pk "$4" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "pub_key": $pk, "extra": $ex}' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; else jq --arg p "$1" --arg n "$2" --arg t "$3" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "extra": $ex}' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; fi; }
_del_node_meta() { [ -f "$META_FILE" ] && jq --arg p "$1" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; }
_get_node_meta() { [ -f "$META_FILE" ] && jq -r --arg p "$1" --arg f "$2" '.[$p][$f] // empty' "$META_FILE"; }
open_port() {
    local port=$1 proto="${2:-tcp}" opened=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then ufw allow ${port}/${proto} >/dev/null 2>&1 && opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1 && opened=1 || iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1 && opened=1; fi
    [ "$opened" -eq 1 ] && echo -e "${G}  ✅ 放行 ${proto^^} ${port}${R}" || echo -e "${Y}  ⚠ 请在云控制台【安全组】放行 ${proto^^} ${port}${R}"
}
open_port_both() { open_port "$1" "tcp"; open_port "$1" "udp"; }

# ★ 新增：端口范围放行函数
open_port_range() {
    local start_port=$1 end_port=$2 proto="${3:-udp}" opened=0
    local port_count=$((end_port - start_port + 1))
    if [ "$port_count" -le 0 ] || [ "$start_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
        echo -e "${RED}  ❌ 端口范围无效: ${start_port}-${end_port}${R}"
        return 1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${start_port}:${end_port}/${proto} >/dev/null 2>&1 && opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${start_port}-${end_port}/${proto} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p ${proto} --dport ${start_port}:${end_port} -j ACCEPT >/dev/null 2>&1 && opened=1 || \
        iptables -I INPUT -p ${proto} --dport ${start_port}:${end_port} -j ACCEPT >/dev/null 2>&1 && opened=1
    fi
    if [ "$opened" -eq 1 ]; then
        echo -e "${G}  ✅ 放行 ${proto^^} ${start_port}-${end_port} (共${port_count}个端口)${R}"
    else
        echo -e "${Y}  ⚠ 请在云控制台【安全组】放行 ${proto^^} ${start_port}-${end_port} (共${port_count}个端口)${R}"
    fi
    return 0
}

sb_add_reality() {
    sb_check || { read -rs -n 1 -p ""; return; }
    read -e -p "端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误${R}"; return; }
    local sni; sni=$(select_sni)
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null); [ -z "$uuid" ] && { echo -e "${RED}UUID生成失败${R}"; return; }
    local keys_output priv_key pub_key; keys_output=$(sing-box generate reality-keypair 2>&1)
    if [ $? -ne 0 ]; then echo -e "${RED}密钥生成失败${R}"; return; fi
    priv_key=$(echo "$keys_output" | grep -i "PrivateKey" | awk '{print $2}'); pub_key=$(echo "$keys_output" | grep -i "PublicKey" | awk '{print $2}')
    [ -z "$priv_key" ] || [ -z "$pub_key" ] && { echo -e "${RED}密钥解析失败${R}"; return; }
    local short_ids=("aabbccdd" "11223344" "deadbeef" "12345678" "abcdef01"); short_id=${short_ids[$((RANDOM % ${#short_ids[@]}))]}
    read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-Reality-${port}"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" '{"type":"vless","tag":("vless-reality-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-reality" "$pub_key" "short_id=${short_id}"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; else echo -e "${G}✅ 成功\nPublicKey: ${pub_key}\nshort_id: ${short_id}${R}"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; fi; read -rs -n 1 -p ""
}
sb_add_vless_ws() {
    sb_check || { read -rs -n 1 -p ""; return; }
    read -e -p "端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误${R}"; return; }
    local ws_path="/$(openssl rand -hex 8)"; read -e -p "WS Path (回车默认): " wp; [ -n "$wp" ] && ws_path="$wp"
    read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-WS-${port}"
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null); [ -z "$uuid" ] && { echo -e "${RED}UUID失败${R}"; return; }
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg wp "$ws_path" '{"type":"vless","tag":("vless-ws-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u}],"transport":{"type":"ws","path":$wp}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-ws" "" "path=${ws_path}"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; else echo -e "${G}✅ 成功 | Path: ${ws_path}${R}"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; fi; read -rs -n 1 -p ""
}
sb_add_hysteria2() {
    sb_check || { read -rs -n 1 -p ""; return; }
    read -e -p "主端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误${R}"; return; }
    if [ -f "/etc/sing-box/config.json" ] && jq -e . "/etc/sing-box/config.json" >/dev/null 2>&1; then
        local dup_port=$(jq -r --argjson p "$port" '.inbounds[] | select(.listen_port == $p) | .tag' "/etc/sing-box/config.json" 2>/dev/null)
        if [ -n "$dup_port" ]; then echo -e "${RED}❌ 端口 ${port} 已被 [${dup_port}] 占用！${R}"; read -rs -n 1 -p ""; return; fi
    fi
    local hop_range=""; read -e -p "需要NAT端口跳跃吗？(y/n): " need_hop
    if [[ "$need_hop" =~ ^[Yy]$ ]]; then
        read -e -p "跳跃范围(如20000-21000): " hop_range
        if [[ ! "$hop_range" =~ ^[0-9]+-[0-9]+$ ]]; then
            echo -e "${RED}格式错误，应为 起始端口-结束端口，如 20000-21000${R}"
            hop_range=""
        else
            local hop_start="${hop_range%-*}" hop_end="${hop_range#*-}"
            if [ "$hop_start" -ge "$hop_end" ] || [ "$hop_end" -gt 65535 ]; then
                echo -e "${RED}范围无效${R}"; hop_range=""
            fi
        fi
    fi
    read -e -p "密码 (回车生成): " pwd; [ -z "$pwd" ] && pwd=$(openssl rand -base64 24 | tr -d '\n/=+' | head -c 32)
    read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="Hysteria2-${port}"
    echo -e "${Y}1.Let's Encrypt 2.手动证书 3.自签${R}"; read -e -p "TLS选择: " tls_choice; local tls_obj="" domain="" tls_method=""
    case "$tls_choice" in
        1) read -e -p "域名: " domain; [ -z "$domain" ] && { echo -e "${RED}空${R}"; return; }; tls_obj=$(jq -n --arg d "$domain" '{"enabled":true,"server_name":$d,"acme":{"domain":$d,"directory":"/etc/sing-box/acme","email":"admin@\($d)"}}'); tls_method="acme" ;;
        2) local c k; read -e -p "证书路径: " c; read -e -p "密钥路径: " k; [ ! -f "$c" ] || [ ! -f "$k" ] && { echo -e "${RED}不存在${R}"; return; }; tls_obj=$(jq -n --arg c "$c" --arg k "$k" '{"enabled":true,"certificate_path":$c,"key_path":$k}'); tls_method="manual" ;;
        3) local d="/etc/sing-box/certs/hy2-${port}"; mkdir -p "$d"; openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "${d}/key.pem" -out "${d}/cert.pem" -subj "/CN=hysteria2" 2>/dev/null; if [ ! -f "${d}/cert.pem" ] || [ ! -f "${d}/key.pem" ]; then echo -e "${RED}证书生成失败${R}"; return; fi; tls_obj=$(jq -n --arg c "${d}/cert.pem" --arg k "${d}/key.pem" '{"enabled":true,"certificate_path":$c,"key_path":$k}'); tls_method="selfsign" ;;
        *) return ;;
    esac
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg pwd "$pwd" --argjson tls "$tls_obj" '{"type":"hysteria2","tag":("hysteria2-"+($p|tostring)),"listen":"::","listen_port":$p,"up_mbps":100,"down_mbps":100,"users":[{"password":$pwd}],"tls":$tls}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        # 放行主端口
        open_port_both "$port"
        # ★ 放行跳跃端口范围
        if [ -n "$hop_range" ]; then
            local hop_start="${hop_range%-*}" hop_end="${hop_range#*-}" main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
            # 自动放行整个跳跃范围的 UDP 端口
            open_port_range "$hop_start" "$hop_end" "udp"
            # 添加 NAT DNAT 规则
            if [ -n "$main_nic" ]; then
                iptables -t nat -A PREROUTING -i "$main_nic" -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${port}
                echo -e "${G}✅ NAT跳跃: UDP ${hop_start}-${hop_end} -> ${port}${R}"
                command -v iptables-save >/dev/null 2>&1 && { iptables-save > /etc/iptables.rules 2>/dev/null; grep -q "iptables-restore" /etc/rc.local 2>/dev/null || sed -i '/^exit 0/i iptables-restore < /etc/iptables.rules' /etc/rc.local 2>/dev/null; }
            else
                echo -e "${Y}⚠ 未检测到默认网卡，NAT 规则未添加${R}"
                hop_range=""
            fi
        fi
        _save_node_meta "$port" "$nn" "hysteria2" "" "password=${pwd};hop_range=${hop_range};tls_method=${tls_method}"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; else echo -e "${G}✅ 成功 | 密码: ${pwd} | 跳跃: ${hop_range:-无}${R}"; fi
    else echo -e "${RED}❌ 校验失败，具体原因：${R}"; sing-box check -c "$conf" 2>&1; echo -e "${Y}正在回滚...${R}"; local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"; _del_node_meta "$port"; fi; read -rs -n 1 -p "按任意键返回..."
}
sb_list_nodes() {
    sb_check || { read -rs -n 1 -p ""; return; }
    local conf="/etc/sing-box/config.json"
    [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1 && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    echo -e "${Y}===== 节点列表 =====${R}"; local idx=1
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port; port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        local tag; tag=$(echo "$obj" | jq -r '.tag // empty' 2>/dev/null)
        local inb_type; inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        local display="$inb_type"
        case "$inb_type" in vless) display="VLESS" ;; hysteria2) display="Hysteria2" ;; vmess) display="VMess" ;; trojan) display="Trojan" ;; esac
        local nn=$(_get_node_meta "$port" "name"); [ -z "$nn" ] && nn="$tag"
        # 显示跳跃端口信息
        local hop_info=""
        local ex=$(_get_node_meta "$port" "extra")
        if [ -n "$ex" ] && echo "$ex" | grep -q "hop_range="; then
            local hr=$(echo "$ex" | grep -oP 'hop_range=\K[^;]+')
            [ -n "$hr" ] && hop_info=" | 跳跃: ${hr}"
        fi
        echo -e "${G}[${idx}] ${display} | 端口: ${port}${hop_info} | ${nn}${R}"
        idx=$((idx + 1))
    done < <(jq -r '.inbounds[] | @base64' "$conf" 2>/dev/null)
    [ $idx -eq 1 ] && echo -e "${Y}无节点${R}"
    read -rs -n 1 -p ""
}
sb_gen_links() {
    sb_check || { read -rs -n 1 -p ""; return; }
    local conf="/etc/sing-box/config.json"
    [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1 && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }

    local server_ip=$(get_my_ip)
    if [ "$server_ip" = "未知IP" ]; then
        read -e -p "无法自动获取IP，请输入服务器IP或域名: " server_ip
        [ -z "$server_ip" ] && { echo -e "${RED}地址不能为空${R}"; read -rs -n 1 -p ""; return; }
    fi

    echo -e "\n${Y}===== 节点链接 =====${R}"
    echo -e "${H}服务器地址: ${server_ip}${R}\n"

    local idx=1 has_link=0
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port; port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        local inb_type; inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        local nn=$(_get_node_meta "$port" "name")
        [ -z "$nn" ] && nn=$(echo "$obj" | jq -r '.tag // empty' 2>/dev/null)
        local link=""

        case "$inb_type" in
            vless)
                local uuid; uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                [ -z "$uuid" ] && { idx=$((idx + 1)); continue; }
                local flow; flow=$(echo "$obj" | jq -r '.users[0].flow // empty' 2>/dev/null)
                local tls_enabled; tls_enabled=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)

                if [ "$tls_enabled" = "true" ] && echo "$obj" | jq -e '.tls.reality' >/dev/null 2>&1; then
                    local sni; sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                    local pub_key; pub_key=$(_get_node_meta "$port" "pub_key")
                    local short_id; short_id=$(echo "$obj" | jq -r '.tls.reality.short_id[0] // empty' 2>/dev/null)
                    if [ -z "$short_id" ]; then
                        local ex=$(_get_node_meta "$port" "extra")
                        [ -n "$ex" ] && short_id=$(echo "$ex" | grep -oP 'short_id=\K[^;]+')
                    fi
                    local flow_param=""
                    [ -n "$flow" ] && flow_param="&flow=${flow}"
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#$(url_encode "$nn")"
                else
                    local ws_path; ws_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null)
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path:-/}")#$(url_encode "$nn")"
                fi
                ;;
            hysteria2)
                local pwd; pwd=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                [ -z "$pwd" ] && { idx=$((idx + 1)); continue; }
                local sni; sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                local insecure="0"
                local ex=$(_get_node_meta "$port" "extra")
                if echo "$ex" | grep -q "tls_method=selfsign"; then
                    insecure="1"
                fi
                # ★ 获取跳跃端口范围，链接中使用范围端口
                local link_port="$port"
                local hop_hint=""
                if [ -n "$ex" ] && echo "$ex" | grep -q "hop_range="; then
                    local hr=$(echo "$ex" | grep -oP 'hop_range=\K[^;]+')
                    if [ -n "$hr" ] && [[ "$hr" =~ ^[0-9]+-[0-9]+$ ]]; then
                        link_port="$hr"
                        hop_hint=" (端口跳跃已启用)"
                    fi
                fi
                local sni_param=""
                [ -n "$sni" ] && sni_param="&sni=${sni}"
                link="hysteria2://$(url_encode "$pwd")@${server_ip}:${link_port}?insecure=${insecure}${sni_param}#$(url_encode "$nn")"
                if [ -n "$hop_hint" ]; then
                    echo -e "${G}[${idx}] ${nn}${Y}${hop_hint}${R}"
                else
                    echo -e "${G}[${idx}] ${nn}${R}"
                fi
                echo -e "${C}${link}${R}\n"
                has_link=1
                idx=$((idx + 1))
                continue
                ;;
        esac

        if [ -n "$link" ]; then
            echo -e "${G}[${idx}] ${nn}${R}"
            echo -e "${C}${link}${R}\n"
            has_link=1
        fi
        idx=$((idx + 1))
    done < <(jq -r '.inbounds[] | @base64' "$conf" 2>/dev/null)

    [ "$has_link" -eq 0 ] && echo -e "${Y}无可用节点链接${R}"
    read -rs -n 1 -p ""
}
sb_del_node() {
    sb_check || { read -rs -n 1 -p ""; return; }
    local conf="/etc/sing-box/config.json"
    [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1 && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    echo -e "${Y}===== 删除节点 =====${R}"; local idx=1 ports=()
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port; port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        local tag; tag=$(echo "$obj" | jq -r '.tag // empty' 2>/dev/null)
        local nn=$(_get_node_meta "$port" "name"); [ -z "$nn" ] && nn="$tag"
        # 显示跳跃端口信息
        local hop_info=""
        local ex=$(_get_node_meta "$port" "extra")
        if [ -n "$ex" ] && echo "$ex" | grep -q "hop_range="; then
            local hr=$(echo "$ex" | grep -oP 'hop_range=\K[^;]+')
            [ -n "$hr" ] && hop_info=" | 跳跃: ${hr}"
        fi
        echo -e "${G}[${idx}] 端口: ${port}${hop_info} | ${nn}${R}"
        ports+=("$port")
        idx=$((idx + 1))
    done < <(jq -r '.inbounds[] | @base64' "$conf" 2>/dev/null)
    [ $idx -eq 1 ] && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    read -e -p "删除编号(0返回): " del_idx; [[ ! "$del_idx" =~ ^[0-9]+$ ]] && return; [ "$del_idx" -eq 0 ] && return
    [ "$del_idx" -lt 1 ] || [ "$del_idx" -gt ${#ports[@]} ] && { echo -e "${RED}超范围${R}"; return; }
    local del_port="${ports[$((del_idx - 1))]}"

    # 清理 NAT 端口跳跃规则
    local ex=$(_get_node_meta "$del_port" "extra")
    if [ -n "$ex" ] && echo "$ex" | grep -q "hop_range="; then
        local old_hop=$(echo "$ex" | grep -oP 'hop_range=\K[^;]+')
        if [ -n "$old_hop" ] && [[ "$old_hop" =~ ^[0-9]+-[0-9]+$ ]]; then
            local hop_start="${old_hop%-*}" hop_end="${old_hop#*-}" main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
            if [ -n "$main_nic" ]; then
                iptables -t nat -D PREROUTING -i "$main_nic" -p udp --dport ${hop_start}:${hop_end} -j DNAT --to-destination :${del_port} 2>/dev/null
                echo -e "${Y}已清理 NAT 规则 (UDP ${hop_start}-${hop_end})${R}"
                # ★ 同时尝试清理 iptables INPUT 范围放行规则
                iptables -D INPUT -p udp --dport ${hop_start}:${hop_end} -j ACCEPT 2>/dev/null
                command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables.rules 2>/dev/null
            fi
        fi
    fi

    # 用端口号精确匹配删除
    if jq --argjson p "$del_port" '.inbounds = [.inbounds[] | select(.listen_port != $p)]' "$conf" > /tmp/sb_cfg.json 2>/dev/null; then
        mv -f /tmp/sb_cfg.json "$conf"
        _del_node_meta "$del_port"
        if jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1; then
            systemctl restart sing-box 2>/dev/null
        else
            systemctl stop sing-box 2>/dev/null
            systemctl disable sing-box 2>/dev/null
        fi
        echo -e "${G}✅ 已彻底删除端口 ${del_port} 的节点${R}"
    else
        echo -e "${RED}❌ 删除失败${R}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}
singbox_manager() {
    root_use
    while true; do clear; local sb_s="${RED}未运行${R}"; systemctl is-active --quiet sing-box 2>/dev/null && sb_s="${G}运行中${R}"
        echo -e "${C}===== Sing-Box 节点管理 =====\n状态: ${sb_s}\n1.VLESS Reality\n2.VLESS+WS\n3.Hysteria2\n4.节点列表\n5.节点与链接\n6.删除节点\n7.重启\n8.停止\n9.日志\n0.返回${R}"
        read -e -p "选择: " c
        case $c in 1) sb_add_reality ;; 2) sb_add_vless_ws ;; 3) sb_add_hysteria2 ;; 4) sb_list_nodes ;; 5) sb_list_nodes; sb_gen_links ;; 6) sb_del_node ;; 7) systemctl restart sing-box && echo -e "${G}已重启${R}" ;; 8) systemctl stop sing-box && echo -e "${Y}已停止${R}" ;; 9) journalctl -u sing-box -n 30 --no-pager ;; 0|"") break ;; esac; read -rs -n 1 -p ""; done
}
main_menu() {
    while true; do clear; echo -e "${gl_lv}===== 服务器综合管理 =====\n1.系统信息\n2.内核优化\n3.BBRv3/XanMod\n4.Swap管理\n${gl_hong}5.Sing-Box节点管理${gl_bai}\n0.退出${gl_lv}\n========================${gl_bai}"
        read -e -p "选择: " c
        case $c in 1) show_sys_info ;; 2) Kernel_optimize ;; 3) bbrv3 ;; 4) change_swap_size ;; 5) singbox_manager ;; 0|"") exit 0 ;; esac; done
}
check_env; main_menu
