#!/usr/bin/env bash

# 终极洁癖：捕获退出信号，自动清理临时文件
trap 'rm -f /tmp/sb_cfg.json /tmp/sb_meta.json.* /tmp/c_tmp.json /tmp/sb_tmp.json 2>/dev/null' EXIT INT TERM

# ================= 全局变量与颜色定义 =================
: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[36m}" "${gh_proxy:=https://}"
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"

send_stats() { :; return 0; }
root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    local need_update=0
    for pkg in curl jq openssl iptables wget tar python3 ca-certificates software-properties-common; do
        command -v $pkg >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境 (Ubuntu/Debian)...${R}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl jq openssl iptables wget tar python3 ca-certificates software-properties-common >/dev/null 2>&1
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
    
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
    local current_year=$(date +%Y)
    if [ "$current_year" -lt 2023 ] || [ "$current_year" -gt 2025 ]; then
        echo -e "${Y}检测到系统时间异常($current_year)，正在通过 HTTP 强制校准...${R}"
        local sys_time=$(curl -sI https://www.cloudflare.com 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
        if [ -n "$sys_time" ]; then
            date -s "$sys_time" >/dev/null 2>&1
            echo -e "${G}✅ 系统时间已强制校准${R}"
        else
            echo -e "${RED}⚠ HTTP 校准失败，请确保服务器时间正确，否则 Reality 节点将无法连通！${R}"
        fi
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

    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then swapon /swapfile >/dev/null 2>&1; swap_total=$(free -m | awk '/Swap/{print $2}'); [ "$swap_total" -ge 512 ] && return 0; fi
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${Y}创建 512MB Swap...${R}"; dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null; chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo -e "${G}✅ Swap 完成。${R}"; fi
}
auto_setup_zram() {
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if ! command -v zramctl >/dev/null 2>&1; then apt-get install -y zram-tools >/dev/null 2>&1 || return 1; fi
    echo -e "ALGO=zstd\nPERCENT=50" > /etc/default/zramswap
    systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1
}
check_disk_space() { local available_mb=$(df -m / | tail -1 | awk '{print $4}'); [ "$available_mb" -lt "$1" ] && { echo -e "${RED}磁盘不足${R}"; return 1; }; return 0; }
server_reboot() { read -e -p "是否现在重启？: " c; [[ "$c" =~ ^[Yy]$ ]] && reboot; }
bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then if ! grep -q "tcp_congestion_control = bbr" "$CONF" 2>/dev/null; then sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"; echo "net.ipv4.tcp_congestion_control = bbr" >> "$CONF"; fi; sysctl -p "$CONF" >/dev/null 2>&1; fi
}
change_swap_size() {
    local swap_file="/swapfile" current_swap=$(free -m | awk '/Swap/{print $2}')
    clear; echo -e "${Y}======== Swap 管理 ========\n当前: ${G}${current_swap} MB${R}\n1.1G 2.2G 3.4G 4.6G 5.自定义 6.移除 0.返回"
    read -e -p "选择: " c; local s=""
    case $c in 1) s=1024;; 2) s=2048;; 3) s=4096;; 4) s=6144;; 5) read -e -p "大小(MB): " s; [[ ! "$s" =~ ^[0-9]+$ ]] && return;; 6) swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '/swapfile/d' /etc/fstab; return;; 0|"") return;; esac
    [ -z "$s" ] && return
    swapoff "$swap_file" 2>/dev/null; dd if=/dev/zero of="$swap_file" bs=1M count=$s 2>/dev/null; chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null 2>&1; swapon "$swap_file" >/dev/null 2>&1
    grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${G}✅ 完成${R}"; read -rs -n 1 -p ""
}

_optimize_nic_queues() {
    local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    [ -z "$main_nic" ] && return
    local cpu_count=$(nproc)
    [ "$cpu_count" -le 1 ] && return
    
    local mask=""
    local full_cores=$((cpu_count / 8))
    local remainder=$((cpu_count % 8))
    for i in $(seq 1 $full_cores); do mask="${mask}ff"; done
    if [ $remainder -gt 0 ]; then
        local rem_val=$(( (1 << remainder) - 1 ))
        mask="${mask}$(printf '%02x' $rem_val)"
    fi
    [ -z "$mask" ] && return

    for q in /sys/class/net/$main_nic/queues/rx-*; do
        [ -f "$q/rps_cpus" ] && echo $mask > "$q/rps_cpus" 2>/dev/null
        [ -f "$q/rps_flow_cnt" ] && echo 32768 > "$q/rps_flow_cnt" 2>/dev/null
    done
    for q in /sys/class/net/$main_nic/queues/tx-*; do
        [ -f "$q/xps_cpus" ] && echo $mask > "$q/xps_cpus" 2>/dev/null
    done
    [ -f /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
}

# ================= 内核与网络深度优化 =================
_kernel_optimize_core() {
    local mode_name="$1" scene="${2:-stream_game}" CONF="/etc/sysctl.d/99-yw-optimize.conf"
    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES CC="bbr" QDISC="fq" UDP_RMEM_MIN=131072 TCP_NOTSENT_LOWAT=16384 TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1 HIGH_EXTRA="" STREAM_EXTRA="" GAME_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA="" STREAM_GAME_EXTRA="" TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0 CONNTRACK_MULT=32
    case "$scene" in
        stream_game) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=8; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_budget_usecs = 8000\nnet.core.netdev_max_backlog = 500000\nnet.core.optmem_max = 40960\nnet.core.busy_poll = 50\nnet.core.busy_read = 50\nnet.ipv4.tcp_pacing_ss_ratio = 200\nnet.ipv4.tcp_pacing_ca_ratio = 120' ;;
        high) SWAPPINESS=10; OVERCOMMIT=1; VFS_PRESSURE=50; DIRTY_RATIO=40; DIRTY_BG_RATIO=10; MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; HIGH_EXTRA=$'vm.dirty_ratio = 40\nvm.dirty_background_ratio = 10' ;;
        web) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864; TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15; KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3; WEB_EXTRA=$'net.ipv4.tcp_max_tw_buckets = 524288\nnet.ipv4.tcp_max_syn_backlog = 16384' ;;
        stream) SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; STREAM_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000' ;;
        game) SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=131072; RMEM_MAX=8388608; WMEM_MAX=8388608; TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"; SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072; GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480' ;;
        gateway) SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50; MIN_FREE_KB=32768; RMEM_MAX=8388608; WMEM_MAX=8388608; TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"; SOMAXCONN=65535; BACKLOG=100000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"; SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=30; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=16384; GATEWAY_EXTRA=$'net.core.optmem_max = 20480' ;;
        balanced) SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75; MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"; SCHED_AUTOGROUP=0; THP="always"; NUMA=1; FIN_TIMEOUT=30; KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5; TCP_SLOW_START_AFTER_IDLE=1; BALANCED_EXTRA="vm.overcommit_memory = 0" ;;
    esac
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 2048 ]; then MIN_FREE_KB=65536; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; BACKLOG=50000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 65536\nnet.ipv4.udp_wmem_min = 65536\nnet.ipv4.udp_rmem_max = 8388608\nnet.ipv4.udp_wmem_max = 8388608\nnet.core.netdev_budget = 800\nnet.core.netdev_max_backlog = 50000\nnet.core.optmem_max = 20480'
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; BACKLOG=10000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 10000\nnet.core.optmem_max = 20480'
    else MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"; HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""; STREAM_GAME_EXTRA=""; [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; check_swap; auto_setup_zram; fi
    
    local KVER=$(uname -r | cut -d '-' -f1)
    local KVER_OK=$(echo -e "4.9\n$KVER" | sort -V | head -n 1)
    CC="cubic"; QDISC="fq_codel"
    if [ "$KVER_OK" = "4.9" ]; then modprobe tcp_bbr 2>/dev/null || true; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && { CC="bbr"; QDISC="fq"; }; fi
    
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ] && [ "$MEM_MB_VAL" -ge 1024 ] && STREAM_GAME_EXTRA="${STREAM_GAME_EXTRA:-${STREAM_EXTRA}}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288; [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
    cat > "$CONF" << EOF
# 模式: ${mode_name}|${scene}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
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
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
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
 $HIGH_EXTRA $WEB_EXTRA $STREAM_EXTRA $GAME_EXTRA $BALANCED_EXTRA $GATEWAY_EXTRA $STREAM_GAME_EXTRA
EOF
    local err=$(sysctl -p "$CONF" 2>&1 | grep -cE "Invalid|No such|unknown key" 2>/dev/null) || err=0
    echo -e "${G}应用完成，跳过 ${err} 项不支持参数${R}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then echo -e "\n# YW-optimize\n* soft nofile 1048576\n* hard nofile 1048576" >> /etc/security/limits.conf; fi
    ulimit -n 1048576 2>/dev/null; check_swap >/dev/null 2>&1; bbr_on
    _optimize_nic_queues
    echo -e "${G}${mode_name} 完成！内存: ${MEM_MB_VAL}MB | 算法: ${CC}${R}"; read -rs -n 1 -p ""
}

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal buster releases" | grep -qw "$os_codename"; then echo -e "${RED}XanMod 已停止支持${R}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
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
    if [ "$(uname -m)" = "aarch64" ]; then echo -e "${Y}ARM架构不支持 XanMod${R}"; read -rs -n 1 -p ""; return 0; fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do clear; echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"; read -e -p "选择: " c
        case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; 0|"") break ;; *) break ;; esac; done
    else clear; echo "设置BBR3"; read -e -p "继续？: " c; [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot; fi
}
restore_defaults() {
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    systemctl is-enabled zramswap >/dev/null 2>&1 && { systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; }
    echo -e "${G}已还原所有设置${R}"; read -rs -n 1 -p ""
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
        local cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))
        local cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
        local cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')
        local mem_total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_used_mb=$((mem_total_mb - mem_avail_mb))
        local mem_percent=$(awk "BEGIN{printf \"%.1f\", ${mem_used_mb}*100/(${mem_total_mb}+0.001)}")
        local mem_info="${mem_avail_mb}M/${mem_total_mb}M (${mem_percent}%)"
        local disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
        echo -ne "${H}正在获取外网IP信息...${R}\r"
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
        local tcp_count=$(ss -t state established 2>/dev/null | wc -l)
        local udp_count=$(ss -u state established 2>/dev/null | wc -l)
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
    return 0
}
Kernel_optimize() {
    root_use
    local scenes=("stream_game" "high" "balanced" "web" "stream" "game" "gateway")
    local names=("直播+游戏" "高性能" "均衡" "网站" "纯直播" "纯游戏" "中转网关")
    while true; do
        clear
        local cur_scene=""
        [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur_scene=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $2}' | tr -d ' \t')
        echo -e "${G}╔═══════════════════════════════════╗"
        echo -e "║       Linux 内核网络优化            ║"
        echo -e "╚═══════════════════════════════════╝${R}"
        echo ""
        local i=0
        while [ $i -lt 7 ]; do
            local num=$((i + 1)); local scene="${scenes[$i]}"; local name="${names[$i]}"
            if [ "$cur_scene" = "$scene" ]; then echo -e "  ${Y}▶ ${G}[${num}] ${name}  ◀ 当前${R}"
            else echo -e "    ${H}[${num}] ${name}${R}"; fi
            i=$((i + 1))
        done
        echo -e "    ${H}─────────────────────────────${R}"
        echo -e "    ${H}[8] 还原默认  [9] 远程脚本  [10] 释放缓存  [11] 验证状态  [0] 返回${R}"
        echo ""
        read -e -p "  选择: " c
        case $c in
            1) clear; _kernel_optimize_core "直播+游戏" "stream_game" ;; 2) clear; _kernel_optimize_core "高性能" "high" ;;
            3) clear; _kernel_optimize_core "均衡" "balanced" ;; 4) clear; _kernel_optimize_core "网站" "web" ;;
            5) clear; _kernel_optimize_core "直播" "stream" ;; 6) clear; _kernel_optimize_core "游戏" "game" ;;
            7) clear; _kernel_optimize_core "网关" "gateway" ;; 8) clear; restore_defaults ;;
            9) curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;;
            10) read -e -p "确定释放缓存？: " d; [[ "$d" =~ ^[Yy]$ ]] && sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null ;;
            11) verify_network_status ;; 0|"") break ;;
        esac
    done
}

# ================= Sing-Box 核心 =================
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/.nodes_meta"

if [ ! -f /etc/sing-box/.sub_token ]; then
    mkdir -p /etc/sing-box
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 > /etc/sing-box/.sub_token
    chmod 600 /etc/sing-box/.sub_token
fi
SUB_TOKEN=$(cat /etc/sing-box/.sub_token)

get_my_ip() { 
    local ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || curl -6 -s -f --connect-timeout 3 https://api64.ipify.org 2>/dev/null)
    if [ -z "$ip" ] || [ "$ip" = "未知IP" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
        [ -z "$ip" ] && ip="服务器IP"
    fi
    echo "$ip"
}
url_encode() { printf '%s' "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/@/%40/g'; }
check_port_occupied() { local port=$1; if ss -tunlp | awk '{print $5}' | grep -q ":${port}$"; then return 0; else return 1; fi; }

sb_check() { if ! command -v $SB_BIN >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return 1; fi; return 0; }
sb_init_conf() { 
    if [ ! -f "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1; then 
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","auto_detect_interface":true}}' > "$SB_CONF"
    fi
}
_init_meta_file() { if [ ! -f "$META_FILE" ] || ! jq -e . "$META_FILE" >/dev/null 2>&1; then mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"; chmod 600 "$META_FILE"; fi; }
_save_node_meta() {
    _init_meta_file; local tmp="/tmp/sb_meta.json.$$"
    if [ -n "$4" ]; then jq --arg p "$1" --arg n "$2" --arg t "$3" --arg pk "$4" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "pub_key": $pk, "extra": $ex}' "$META_FILE" > "$tmp"
    else jq --arg p "$1" --arg n "$2" --arg t "$3" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "extra": $ex}' "$META_FILE" > "$tmp"; fi
    [ -s "$tmp" ] && { mv -f "$tmp" "$META_FILE"; chmod 600 "$META_FILE"; } || rm -f "$tmp"
}
_del_node_meta() { _init_meta_file; jq --arg p "$1" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; }
_get_node_meta() { _init_meta_file; jq -r --arg p "$1" --arg f "$2" '.[$p][$f] // empty' "$META_FILE"; }
_clean_bak() { ls -t "${SB_CONF}.bak."* 2>/dev/null | tail -n +2 | xargs rm -f 2>/dev/null; }

_open_single_port() {
    local port=$1 proto="${2:-tcp}" opened=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${port}/${proto} >/dev/null 2>&1; opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; opened=1
    elif command -v iptables >/dev/null 2>&1; then
        modprobe iptable_nat 2>/dev/null || true
        iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
        fi
        opened=1
    fi
    if [ "$opened" -eq 1 ]; then echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}"; else echo -e "${Y}  ⚠ 自动放行失败，请手动在云控制台放行 ${proto^^} ${port}${R}"; fi
}
open_port_both() { _open_single_port "$1" "tcp"; _open_single_port "$1" "udp"; }

_del_single_port() {
    local port=$1 proto="${2:-tcp}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow ${port}/${proto} >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port=${port}/${proto} >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
        command -v ip6tables >/dev/null 2>&1 && ip6tables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
    fi
}
del_port_both() { _del_single_port "$1" "tcp"; _del_single_port "$1" "udp"; }

_persist_iptables() {
    local ipt_save=$(command -v iptables-save)
    local ip6t_save=$(command -v ip6tables-save)
    local ipt_rest=$(command -v iptables-restore)
    local ip6t_rest=$(command -v ip6tables-restore)
    
    [ -n "$ipt_save" ] && $ipt_save > /etc/iptables.rules 2>/dev/null
    [ -n "$ip6t_save" ] && $ip6t_save > /etc/ip6tables.rules 2>/dev/null

    cat > /etc/systemd/system/sb-iptables.service <<EOF
[Unit]
Description=Restore iptables rules for Sing-Box
After=network-pre.target
Before=network.target
[Service]
Type=oneshot
ExecStart=$ipt_rest /etc/iptables.rules
 $([ -n "$ip6t_rest" ] && echo "ExecStart=$ip6t_rest /etc/ip6tables.rules")
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable sb-iptables.service >/dev/null 2>&1
}

sb_install() {
    if command -v $SB_BIN >/dev/null 2>&1; then echo -e "${Y}Sing-Box 已安装！${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) echo -e "${RED}❌ 不支持 ${arch}${R}"; return 1;; esac
    echo -e "${Y}即将安装 Sing-Box (${arch})${R}"; read -e -p "继续？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    local latest_ver=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//')
    [ -z "$latest_ver" ] && latest_ver="1.10.7"
    mkdir -p /etc/sing-box
    if curl -L -o /tmp/sb.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"; then
        tar xzf /tmp/sb.tar.gz -C /tmp; mv /tmp/sing-box-${latest_ver}-linux-${arch}/sing-box $SB_BIN
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-${latest_ver}-linux-${arch}; chmod +x $SB_BIN
        sb_init_conf
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
LimitNPROC=infinity
OOMScoreAdjust=-1000
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl start sing-box
        echo -e "${G}✅ 安装成功 | 版本: $($SB_BIN version 2>/dev/null | head -1)${R}"
    else echo -e "${RED}❌ 下载失败${R}"; fi
    read -rs -n 1 -p ""
}
sb_update() {
    if ! command -v $SB_BIN >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) return 1;; esac
    local latest_ver=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//')
    [ -z "$latest_ver" ] && latest_ver="1.10.7"
    if curl -L -o /tmp/sb.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"; then
        tar xzf /tmp/sb.tar.gz -C /tmp; systemctl stop sing-box >/dev/null 2>&1
        mv /tmp/sing-box-${latest_ver}-linux-${arch}/sing-box $SB_BIN
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-${latest_ver}-linux-${arch}; chmod +x $SB_BIN
        systemctl start sing-box >/dev/null 2>&1; echo -e "${G}✅ 更新成功 | 版本: $($SB_BIN version 2>/dev/null | head -1)${R}"
    else echo -e "${RED}❌ 下载失败${R}"; fi
    read -rs -n 1 -p ""
}
sb_uninstall() {
    if ! command -v $SB_BIN >/dev/null 2>&1; then echo -e "${Y}Sing-Box 未安装${R}"; read -rs -n 1 -p ""; return; fi
    read -e -p "确认卸载？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop sing-box sb-sub sb-iptables >/dev/null 2>&1
    systemctl disable sing-box sb-sub sb-iptables >/dev/null 2>&1
    rm -rf /etc/sing-box $SB_BIN /etc/systemd/system/sing-box.service /etc/systemd/system/sb-sub.service /etc/systemd/system/sb-iptables.service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
    echo -e "${G}✅ Sing-Box 已完全卸载${R}"; read -rs -n 1 -p ""
}
sb_view_log() {
    echo -e "${Y}退出日志请按 Ctrl+C${R}"
    journalctl -u sing-box -f -n 50
}

# ================= 节点添加逻辑 =================
_get_port() {
    local port=$1; local input_port
    while true; do
        echo -e "${Y}提示：如果云服务器有安全组限制，请输入已在安全组放行的端口${R}"
        read -e -p "端口 (回车默认随机 $port): " input_port
        [[ "$input_port" =~ ^[0-9]+$ ]] && port="$input_port"
        if check_port_occupied "$port"; then echo -e "${RED}❌ 端口 $port 已被占用，请重新输入！${R}"; else break; fi
    done
    echo "$port"
}

sb_add_reality() {
    sb_check || return
    local current_year=$(date +%Y)
    if [ "$current_year" -gt 2025 ]; then
        echo -e "${RED}警告：服务器时间异常($current_year)，Reality 将无法连通！建议用 Hy2/Tuic。${R}"
        read -e -p "是否继续？: " rc; [[ ! "$rc" =~ ^[Yy]$ ]] && return
    fi
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    local sni="www.microsoft.com"
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local keys_output priv_key pub_key; keys_output=$($SB_BIN generate reality-keypair 2>&1)
    priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}' | tr -d '\r'); pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}' | tr -d '\r')
    [ -z "$priv_key" ] || [ -z "$pub_key" ] && { echo -e "${RED}密钥生成失败${R}"; return; }
    local short_id=$($SB_BIN generate rand --hex 4 2>/dev/null || echo "aabbccdd")
    local nn; read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-Reality-${port}"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" '{"type":"vless","tag":("vless-reality-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-reality" "$pub_key" "short_id=${short_id}"
        systemctl restart sing-box; sleep 2
        if systemctl is-active --quiet sing-box; then echo -e "${G}✅ 成功 | PublicKey: ${pub_key}${R}"; sb_sync_client_config; _persist_iptables; else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_vless_ws() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    local ws_path="/$(openssl rand -hex 8)"; read -e -p "WS Path (回车默认): " wp; [ -n "$wp" ] && ws_path="$wp"
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local nn; read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-WS-${port}"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg wp "$ws_path" '{"type":"vless","tag":("vless-ws-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u}],"transport":{"type":"ws","path":$wp}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-ws" "" "path=${ws_path}"
        systemctl restart sing-box; sleep 2
        if systemctl is-active --quiet sing-box; then echo -e "${G}✅ 成功 | Path: ${ws_path}${R}"; sb_sync_client_config; _persist_iptables; else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_hysteria2() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    local pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local nn; read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="Hysteria2-${port}"
    
    local cert_dir="/etc/sing-box/certs/hy2-${port}"; mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    chmod 600 "${cert_dir}/key.pem"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg pwd "$pwd" --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" '{"type":"hysteria2","tag":("hysteria2-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"password":$pwd}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$c,"key_path":$k}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "hysteria2" "" "password=${pwd};tls_method=selfsign;sni=www.bing.com"
        systemctl restart sing-box; sleep 2
        if systemctl is-active --quiet sing-box; then echo -e "${G}✅ 成功 | 密码: ${pwd}${R}"; sb_sync_client_config; _persist_iptables; else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_tuic() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local nn; read -e -p "名称 (回车默认): " nn; [ -z "$nn" ] && nn="TUIC-${port}"
    
    local cert_dir="/etc/sing-box/certs/tuic-${port}"; mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    chmod 600 "${cert_dir}/key.pem"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg pwd "$pwd" --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" '{"type":"tuic","tag":("tuic-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"password":$pwd}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$c,"key_path":$k}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "tuic" "" "uuid=${uuid};password=${pwd};tls_method=selfsign;sni=www.bing.com"
        systemctl restart sing-box; sleep 2
        if systemctl is-active --quiet sing-box; then echo -e "${G}✅ 成功 | UUID: ${uuid} | 密码: ${pwd}${R}"; sb_sync_client_config; _persist_iptables; else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; _del_node_meta "$port"; fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_all() {
    sb_check || return
    echo -e "${Y}将自动部署 VLESS-Reality, VLESS-WS, Hysteria2, TUIC 四协议${R}"
    local base_port; read -e -p "输入起始端口 (将自动占用连续4个端口): " base_port
    [[ ! "$base_port" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误${R}"; return; }
    
    local p_re=$base_port p_ws=$((base_port + 1)) p_hy=$((base_port + 2)) p_tu=$((base_port + 3))
    for p in $p_re $p_ws $p_hy $p_tu; do
        if check_port_occupied "$p"; then echo -e "${RED}❌ 端口 $p 被占用，请更换起始端口！${R}"; return; fi
    done
    
    local sni="www.microsoft.com"
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local keys_output priv_key pub_key; keys_output=$($SB_BIN generate reality-keypair 2>&1)
    priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}' | tr -d '\r'); pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}' | tr -d '\r')
    local short_id=$($SB_BIN generate rand --hex 4 2>/dev/null || echo "aabbccdd")
    local ws_path="/$(openssl rand -hex 8)"
    local hy_pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local tu_uuid=$($SB_BIN generate uuid 2>/dev/null)
    local tu_pwd=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    
    mkdir -p /etc/sing-box/certs/hy2-${p_hy} /etc/sing-box/certs/tuic-${p_tu}
    openssl ecparam -genkey -name prime256v1 -out "/etc/sing-box/certs/hy2-${p_hy}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "/etc/sing-box/certs/hy2-${p_hy}/key.pem" -out "/etc/sing-box/certs/hy2-${p_hy}/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    chmod 600 "/etc/sing-box/certs/hy2-${p_hy}/key.pem"
    openssl ecparam -genkey -name prime256v1 -out "/etc/sing-box/certs/tuic-${p_tu}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "/etc/sing-box/certs/tuic-${p_tu}/key.pem" -out "/etc/sing-box/certs/tuic-${p_tu}/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null
    chmod 600 "/etc/sing-box/certs/tuic-${p_tu}/key.pem"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij_re=$(jq -n --argjson p "$p_re" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" '{"type":"vless","tag":("vless-reality-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}')
    local ij_ws=$(jq -n --argjson p "$p_ws" --arg u "$uuid" --arg wp "$ws_path" '{"type":"vless","tag":("vless-ws-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u}],"transport":{"type":"ws","path":$wp}}')
    local ij_hy=$(jq -n --argjson p "$p_hy" --arg pwd "$hy_pwd" --arg c "/etc/sing-box/certs/hy2-${p_hy}/cert.pem" --arg k "/etc/sing-box/certs/hy2-${p_hy}/key.pem" '{"type":"hysteria2","tag":("hysteria2-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"password":$pwd}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$c,"key_path":$k}}')
    local ij_tu=$(jq -n --argjson p "$p_tu" --arg u "$tu_uuid" --arg pwd "$tu_pwd" --arg c "/etc/sing-box/certs/tuic-${p_tu}/cert.pem" --arg k "/etc/sing-box/certs/tuic-${p_tu}/key.pem" '{"type":"tuic","tag":("tuic-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"password":$pwd}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$c,"key_path":$k}}')
    
    jq --argjson re "$ij_re" --argjson ws "$ij_ws" --argjson hy "$ij_hy" --argjson tu "$ij_tu" '.inbounds += [$re, $ws, $hy, $tu]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        open_port_both "$p_re"; open_port_both "$p_ws"; open_port_both "$p_hy"; open_port_both "$p_tu"
        _save_node_meta "$p_re" "VLESS-Reality" "vless-reality" "$pub_key" "short_id=${short_id}"
        _save_node_meta "$p_ws" "VLESS-WS" "vless-ws" "" "path=${ws_path}"
        _save_node_meta "$p_hy" "Hysteria2" "hysteria2" "" "password=${hy_pwd};tls_method=selfsign;sni=www.bing.com"
        _save_node_meta "$p_tu" "TUIC" "tuic" "" "uuid=${tu_uuid};password=${tu_pwd};tls_method=selfsign;sni=www.bing.com"
        systemctl restart sing-box; sleep 2
        if systemctl is-active --quiet sing-box; then echo -e "${G}✅ 四协议部署成功！${R}"; sb_sync_client_config; _persist_iptables; else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
            for p in $p_re $p_ws $p_hy $p_tu; do _del_node_meta "$p"; done; fi
    else echo -e "${RED}校验失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; fi
    _clean_bak; read -rs -n 1 -p ""
}

# ================= 客户端配置与订阅 =================
sb_sync_client_config() {
    local server_ip=$(get_my_ip)
    local client_conf="/etc/sing-box/client.json"
    
    if [ ! -f "$SB_CONF" ] || ! jq -e '.inbounds[0]' "$SB_CONF" >/dev/null 2>&1; then
        jq -n '{log:{"level":"info"}, inbounds:[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30","fd00::1/126"],"auto_route":true,"strict_route":true}], outbounds:[{"type":"direct","tag":"direct"}], route:{"final":"direct","auto_detect_interface":true}}' > $client_conf
        if systemctl is-active --quiet sb-sub 2>/dev/null; then
            mkdir -p /etc/sing-box/sub
            cp $client_conf /etc/sing-box/sub/$SUB_TOKEN.json 2>/dev/null
        fi
        return 0
    fi

    jq -n '{log:{"level":"info"}, inbounds:[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30","fd00::1/126"],"auto_route":true,"strict_route":true}], outbounds:[], route:{"final":"proxy","auto_detect_interface":true}}' > $client_conf
    
    local tags_json='[]'
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port inb_type nn ex pub_key short_id ws_path pwd sni uuid tu_pwd
        port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        nn=$(_get_node_meta "$port" "name"); [ -z "$nn" ] && continue
        inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        ex=$(_get_node_meta "$port" "extra")
        
        local ob=""
        case "$inb_type" in
            vless)
                uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                if echo "$obj" | jq -e '.tls.reality' >/dev/null 2>&1; then
                    sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null); pub_key=$(_get_node_meta "$port" "pub_key")
                    short_id=$(echo "$ex" | sed -n 's/.*short_id=\([^;]*\).*/\1/p')
                    ob=$(jq -n --arg n "$nn" --arg s "$server_ip" --argjson p "$port" --arg u "$uuid" --arg sni "$sni" --arg pk "$pub_key" --arg sid "$short_id" '{"tag":$n,"type":"vless","server":$s,"server_port":$p,"uuid":$u,"flow":"xtls-rprx-vision","tls":{"enabled":true,"server_name":$sni,"utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":$pk,"short_id":$sid}}}')
                else
                    ws_path=$(echo "$ex" | sed -n 's/.*path=\([^;]*\).*/\1/p')
                    ob=$(jq -n --arg n "$nn" --arg s "$server_ip" --argjson p "$port" --arg u "$uuid" --arg wp "$ws_path" '{"tag":$n,"type":"vless","server":$s,"server_port":$p,"uuid":$u,"tls":{"enabled":false},"transport":{"type":"ws","path":$wp}}')
                fi ;;
            hysteria2)
                pwd=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p'); sni="www.bing.com"
                ob=$(jq -n --arg n "$nn" --arg s "$server_ip" --argjson p "$port" --arg pwd "$pwd" --arg sni "$sni" '{"tag":$n,"type":"hysteria2","server":$s,"server_port":$p,"password":$pwd,"tls":{"enabled":true,"insecure":true,"server_name":$sni,"alpn":["h3"]}}') ;;
            tuic)
                uuid=$(echo "$ex" | sed -n 's/.*uuid=\([^;]*\).*/\1/p'); pwd=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p'); sni="www.bing.com"
                ob=$(jq -n --arg n "$nn" --arg s "$server_ip" --argjson p "$port" --arg u "$uuid" --arg pwd "$pwd" --arg sni "$sni" '{"tag":$n,"type":"tuic","server":$s,"server_port":$p,"uuid":$u,"password":$pwd,"congestion_control":"bbr","tls":{"enabled":true,"insecure":true,"server_name":$sni,"alpn":["h3"]}}') ;;
        esac
        
        if [ -n "$ob" ]; then
            jq --argjson ob "$ob" '.outbounds += [$ob]' $client_conf > /tmp/c_tmp.json && mv /tmp/c_tmp.json $client_conf
            tags_json=$(echo "$tags_json" | jq --arg n "$nn" '. += [$n]')
        fi
    done < <(jq -r '.inbounds[] | @base64' "$SB_CONF" 2>/dev/null)
    
    if [ "$tags_json" != "[]" ]; then
        local selector=$(jq -n --argjson tags "$tags_json" '{"type":"selector","tag":"proxy","outbounds":($tags + ["auto"])}')
        jq --argjson ob "$selector" '.outbounds += [$ob]' $client_conf > /tmp/c_tmp.json && mv /tmp/c_tmp.json $client_conf
        local urltest=$(jq -n --argjson tags "$tags_json" '{"type":"urltest","tag":"auto","outbounds":$tags,"url":"http://www.gstatic.com/generate_204","interval":"10m"}')
        jq --argjson ob "$urltest" '.outbounds += [$ob]' $client_conf > /tmp/c_tmp.json && mv /tmp/c_tmp.json $client_conf
    fi
    local direct=$(jq -n '{"type":"direct","tag":"direct"}')
    jq --argjson ob "$direct" '.outbounds += [$ob]' $client_conf > /tmp/c_tmp.json && mv /tmp/c_tmp.json $client_conf
    
    if systemctl is-active --quiet sb-sub 2>/dev/null; then
        mkdir -p /etc/sing-box/sub
        cp $client_conf /etc/sing-box/sub/$SUB_TOKEN.json 2>/dev/null
    fi
}

sb_generate_client_config() {
    sb_check || return
    if [ ! -f "$SB_CONF" ] || ! jq -e '.inbounds[0]' "$SB_CONF" >/dev/null 2>&1; then
        echo -e "${RED}当前没有任何节点，无法生成客户端配置！${R}"
        read -rs -n 1 -p ""; return
    fi
    sb_sync_client_config
    echo -e "${G}客户端配置已生成并同步至: /etc/sing-box/client.json${R}"
    cat /etc/sing-box/client.json
    read -rs -n 1 -p ""
}

sb_start_sub_server() {
    sb_check || return
    if systemctl is-active --quiet sb-sub 2>/dev/null; then echo -e "${Y}订阅服务已在运行${R}"; read -rs -n 1 -p ""; return; fi
    local server_ip=$(get_my_ip)
    [ "$server_ip" = "未知IP" ] && { echo -e "${RED}无法获取IP${R}"; return; }
    
    local py_bin=$(command -v python3)
    if [ -z "$py_bin" ]; then
        echo -e "${RED}未找到 Python3 环境，无法启动订阅服务${R}"; return 1
    fi
    
    sb_sync_client_config
    
    cat > /etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=Sing-Box Subscription Server
After=network.target
[Service]
Type=simple
WorkingDirectory=/etc/sing-box/sub
ExecStart=$py_bin -m http.server 8191 --bind 0.0.0.0 --directory /etc/sing-box/sub
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sb-sub >/dev/null 2>&1
    _open_single_port 8191 "tcp"
    _persist_iptables
    echo -e "${G}✅ 订阅服务已启动并设置为开机自启${R}"
    echo -e "${Y}订阅链接 (Base64): http://${server_ip}:8191/${SUB_TOKEN}.json${R}"
    read -rs -n 1 -p ""
}

sb_show_nodes_and_links() {
    sb_check || return
    local server_ip=$(get_my_ip)
    echo -e "\n${Y}===== 节点列表与链接 =====${R}\n${H}服务器地址: ${server_ip}${R}\n"
    local idx=1 has_any=0
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port inb_type nn ex link=""
        port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        nn=$(_get_node_meta "$port" "name"); [ -z "$nn" ] && continue
        inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        ex=$(_get_node_meta "$port" "extra")
        echo -e "${G}━━━ [${idx}] ${inb_type^^} | 端口: ${port} | ${nn} ━━━${R}"; has_any=1
        
        case "$inb_type" in
            vless)
                local uuid flow tls_enabled sni pub_key short_id ws_path
                uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                flow=$(echo "$obj" | jq -r '.users[0].flow // empty' 2>/dev/null); tls_enabled=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)
                if [ "$tls_enabled" = "true" ] && echo "$obj" | jq -e '.tls.reality' >/dev/null 2>&1; then
                    sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null); pub_key=$(_get_node_meta "$port" "pub_key")
                    short_id=$(echo "$ex" | sed -n 's/.*short_id=\([^;]*\).*/\1/p')
                    local flow_param=""; [ -n "$flow" ] && flow_param="&flow=${flow}"
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#$(url_encode "$nn")"
                else
                    ws_path=$(echo "$ex" | sed -n 's/.*path=\([^;]*\).*/\1/p')
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path:-/}")#$(url_encode "$nn")"
                fi ;;
            hysteria2)
                local pwd=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p')
                link="hysteria2://$(url_encode "$pwd")@${server_ip}:${port}?insecure=1&alpn=h3&sni=www.bing.com#$(url_encode "$nn")" ;;
            tuic)
                local uuid=$(echo "$ex" | sed -n 's/.*uuid=\([^;]*\).*/\1/p'); local pwd=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p')
                link="tuic://${uuid}:$(url_encode "$pwd")@${server_ip}:${port}?congestion_control=bbr&alpn=h3&sni=www.bing.com&allow_insecure=1#$(url_encode "$nn")" ;;
        esac
        [ -n "$link" ] && echo -e "${C}${link}${R}\n"; idx=$((idx + 1))
    done < <(jq -r '.inbounds[] | @base64' "$SB_CONF" 2>/dev/null)
    [ "$has_any" -eq 0 ] && echo -e "${Y}无节点${R}"
    read -rs -n 1 -p ""
}

sb_del_node() {
    sb_check || return
    [ ! -f "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1 && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    echo -e "${Y}===== 删除节点 =====${R}"
    local idx=1 has_any=0
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port nn; port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        nn=$(_get_node_meta "$port" "name"); [ -z "$nn" ] && continue
        echo -e "${G}[${idx}] 端口: ${port} | ${nn}${R}"; idx=$((idx + 1)); has_any=1
    done < <(jq -r '.inbounds[] | @base64' "$SB_CONF" 2>/dev/null)
    [ "$has_any" -eq 0 ] && { echo -e "${Y}无节点可删除${R}"; read -rs -n 1 -p ""; return; }
    read -e -p "请输入要删除的端口号: " del_input
    [ -z "$del_input" ] || [[ "$del_input" == "0" ]] && return
    local found_tag=$(jq -r --argjson p "$del_input" '.inbounds[] | select(.listen_port == $p) | .tag' "$SB_CONF" 2>/dev/null | head -1)
    [ -z "$found_tag" ] && { echo -e "${RED}未找到节点${R}"; return; }
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    jq --arg t "$found_tag" 'del(.inbounds[] | select(.tag == $t))' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        _del_node_meta "$del_input"; systemctl restart sing-box
        del_port_both "$del_input"
        rm -rf /etc/sing-box/certs/hy2-${del_input} /etc/sing-box/certs/tuic-${del_input}
        sb_sync_client_config
        _persist_iptables
        echo -e "${G}✅ 已删除并清理残留${R}"
    else echo -e "${RED}校验失败，回滚...${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"; fi
    _clean_bak; read -rs -n 1 -p ""
}

manual_open_port() {
    while true; do
        clear
        echo -e "${Y}===== 手动开放端口 =====${R}"
        echo -e "1. 放行单个端口 (TCP+UDP)"
        echo -e "2. 放行端口范围 (TCP+UDP)"
        echo -e "0. 返回 Sing-Box 菜单"
        read -e -p "请选择: " port_choice
        case "$port_choice" in
            1) read -e -p "请输入端口号: " port; open_port_both "$port"; _persist_iptables; read -rs -n 1 -p "按任意键继续..." ;;
            2) read -e -p "起始端口: " sp; read -e -p "结束端口: " ep; _open_single_port "$sp" "$ep" "tcp"; _open_single_port "$sp" "$ep" "udp"; _persist_iptables; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;; *) echo -e "${RED}无效${R}"; sleep 1 ;;
        esac
    done
}

sb_menu() {
    while true; do
        clear
        local sb_status_text="${H}未安装${R}"
        if command -v $SB_BIN >/dev/null 2>&1; then
            if systemctl is-active --quiet sing-box 2>/dev/null; then sb_status_text="${G}● 运行中${R}"
            else sb_status_text="${RED}○ 未运行${R}"; fi
        fi
        echo -e "${G}╔════════════════════════════════╗"
        echo -e "║       Sing-Box 管理面板            ║"
        echo -e "╚════════════════════════════════╝${R}"
        echo -e "    当前状态: ${sb_status_text}"
        echo ""
        echo -e "    ${H}[1] 添加 VLESS-Reality${R}"
        echo -e "    ${H}[2] 添加 VLESS-WS${R}"
        echo -e "    ${H}[3] 添加 Hysteria2${R}"
        echo -e "    ${H}[4] 添加 TUIC v5${R}"
        echo -e "    ${H}[5] 一键部署四协议${R}"
        echo -e "    ${H}────────────────────────${R}"
        echo -e "    ${H}[6] 查看节点与链接${R}"
        echo -e "    ${H}[7] 删除节点${R}"
        echo -e "    ${H}[8] 生成客户端配置文件${R}"
        echo -e "    ${H}[9] 开启本地订阅服务${R}"
        echo -e "    ${H}────────────────────────${R}"
        echo -e "    ${H}[10] 安装 Sing-Box${R}"
        echo -e "    ${H}[11] 更新 Sing-Box${R}"
        echo -e "    ${H}[12] 卸载 Sing-Box${R}"
        echo -e "    ${H}[13] 重启 Sing-Box${R}"
        echo -e "    ${H}[14] 查看 Sing-Box 日志${R}"
        echo -e "    ${H}[15] 手动开放端口${R}"
        echo ""
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        read -e -p "  选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; sb_add_reality ;; 2) clear; sb_add_vless_ws ;;
            3) clear; sb_add_hysteria2 ;; 4) clear; sb_add_tuic ;;
            5) clear; sb_add_all ;;
            6) clear; sb_show_nodes_and_links ;; 7) clear; sb_del_node ;;
            8) clear; sb_generate_client_config ;; 9) clear; sb_start_sub_server ;;
            10) clear; sb_install ;; 11) clear; sb_update ;; 12) clear; sb_uninstall ;;
            13) clear; systemctl restart sing-box && echo -e "${G}✅ 已重启${R}" || echo -e "${RED}重启失败${R}"; read -rs -n 1 -p "" ;;
            14) clear; sb_view_log ;; 15) clear; manual_open_port ;; 0|"") break ;; *) echo -e "${RED}无效${R}"; sleep 1 ;;
        esac
    done
}

# ================= 主菜单 =================
main_menu() {
    check_env
    while true; do
        clear
        echo -e "${G}╔══════════════════════════════════════╗"
        echo -e "║          YW 服务器优化工具箱            ║"
        echo -e "╚══════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}[1] 系统信息查询${R}"
        echo -e "    ${Y}[2] BBRv3 (XanMod内核)${R}"
        echo -e "    ${Y}[3] Sing-Box 管理面板${R}"
        echo -e "    ${Y}[4] Linux 内核网络优化${R}"
        echo -e "    ${Y}[5] Swap 管理${R}"
        echo ""
        echo -e "    ${H}[0] 退出${R}"
        echo ""
        read -e -p "  请选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) show_sys_info ;; 2) bbrv3 ;; 3) sb_menu ;; 4) Kernel_optimize ;; 5) change_swap_size ;;
            0|"") echo -e "${G}再见！${R}"; exit 0 ;; *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

main_menu
