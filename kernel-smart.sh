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

send_stats() { :; return 0; }
root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    root_use
    local need_update=0
    for cmd in curl jq openssl iptables wget tar python3 ip ss free modprobe ethtool; do
        command -v $cmd >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl jq openssl iptables wget tar python3 ca-certificates iproute2 procps kmod ethtool >/dev/null 2>&1
        if ! command -v jq >/dev/null 2>&1; then
            echo -e "${RED}❌ 核心依赖 jq 安装失败，请检查网络或 apt 源！${R}"
            exit 1
        fi
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
    
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
    local current_year=$(date +%Y)
    if [ "$current_year" -lt 2020 ] || [ "$current_year" -gt 2030 ]; then
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
change_swap_size() {
    local swap_file="/swapfile" current_swap=$(free -m | awk '/Swap/{print $2}')
    clear; echo -e "${Y}======== Swap 管理 ========\n当前: ${G}${current_swap} MB${R}\n1.1G 2.2G 3.4G 4.6G 5.自定义 6.移除 0.返回"
    read -e -p "选择: " c; local s=""
    case $c in 1) s=1024;; 2) s=2048;; 3) s=4096;; 4) s=6144;; 5) read -e -p "大小(MB): " s; [[ ! "$s" =~ ^[0-9]+$ ]] && return;; 6) swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '\#^/swapfile[[:space:]]\+#d' /etc/fstab; return;; 0|"") return;; esac
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
    [ -f /proc/sys/net/core/rps_sock_flow_entries ] && [ -w /proc/sys/net/core/rps_sock_flow_entries ] && echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
}

# ================= 内核与网络深度优化 =================
_kernel_optimize_core() {
    local mode_name="$1" scene="${2:-stream_game}" CONF="/etc/sysctl.d/99-yw-optimize.conf"
    
    rm -f /etc/sysctl.d/99-tiktok-udp.conf /etc/sysctl.d/99-bandwidth.conf /etc/sysctl.d/99-smart.conf 2>/dev/null || true
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
    elif [ "$MEM_MB_VAL" -ge 2048 ]; then MIN_FREE_KB=65536; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; BACKLOG=50000; { [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ]; } && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 65536\nnet.ipv4.udp_wmem_min = 65536\nnet.ipv4.udp_rmem_max = 8388608\nnet.ipv4.udp_wmem_max = 8388608\nnet.core.netdev_budget = 800\nnet.core.netdev_max_backlog = 50000\nnet.core.optmem_max = 20480'
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; BACKLOG=10000; { [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ]; } && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 10000\nnet.core.optmem_max = 20480'
    else MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"; HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""; STREAM_GAME_EXTRA=""; [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; check_swap; auto_setup_zram; fi
    
    local KVER=$(uname -r | cut -d '-' -f1)
    local KVER_OK=$(echo -e "4.9\n$KVER" | sort -V | head -n 1)
    CC="cubic"; QDISC="fq_codel"
    if [ "$KVER_OK" = "4.9" ]; then modprobe tcp_bbr 2>/dev/null || true; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && { CC="bbr"; QDISC="fq"; }; fi
    
    if [ "$scene" = "gateway" ]; then
        modprobe nf_conntrack 2>/dev/null
        CONNTRACK_MULT=128
    fi

    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    if { [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ]; } && [ "$MEM_MB_VAL" -ge 1024 ]; then
        STREAM_GAME_EXTRA="${STREAM_GAME_EXTRA:-${STREAM_EXTRA}}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    fi
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288; [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
    cat > "$CONF" << EOF
# 模式: ${mode_name}|${scene}
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC
net.ipv4.tcp_no_metrics_save = 1
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

# ================= 智能自动优化 (整合版) =================
smart_auto_optimize() {
    clear
    echo -e "${G}╔═══════════════════════════════════════════╗${R}"
    echo -e "${G}║      🚀 智能自动优化 (推荐新手)            ║${R}"
    echo -e "${G}╚═══════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${Y}正在智能检测您的系统配置...${R}"
    sleep 1
    
    local mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local cpu_cores=$(nproc 2>/dev/null || echo 1)
    
    local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    local nic_speed=1000
    if [ -n "$main_nic" ] && command -v ethtool >/dev/null 2>&1; then
        local detected_speed=$(ethtool "$main_nic" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/Mb\/s//')
        if [[ "$detected_speed" =~ ^[0-9]+$ ]]; then
            nic_speed="$detected_speed"
        fi
    fi
    
    echo -e "  - 内存: ${Y}${mem_mb}MB${R}"
    echo -e "  - 核心数: ${Y}${cpu_cores}${R}"
    echo -e "  - 网络: ${Y}${nic_speed}Mbps${R}"
    echo ""
    echo -e "${Y}即将自动优化：${R}"
    echo -e "  • 网络参数优化 (BBR+fq，包含TikTok直播优化)"
    echo -e "  • 内存优化 (根据配置自动调整)"
    echo -e "  • Swap配置"
    echo -e "  • Sing-Box优化 (如果已安装)"
    echo ""
    
    if prompt_yes_no "开始智能优化？(推荐直接回车) " "y"; then
        echo ""
        
        local rmem_max wmem_max somaxconn backlog netdev_budget swappiness dirty_ratio dirty_bg_ratio
        
        if [ "$mem_mb" -lt 512 ]; then
            rmem_max=8388608; wmem_max=8388608; somaxconn=2048; backlog=10000; netdev_budget=300
            swappiness=30; dirty_ratio=5; dirty_bg_ratio=2
        elif [ "$mem_mb" -lt 1024 ]; then
            rmem_max=16777216; wmem_max=16777216; somaxconn=4096; backlog=25000; netdev_budget=600
            swappiness=20; dirty_ratio=15; dirty_bg_ratio=5
        elif [ "$mem_mb" -lt 2048 ]; then
            rmem_max=33554432; wmem_max=33554432; somaxconn=8192; backlog=100000; netdev_budget=800
            swappiness=30; dirty_ratio=20; dirty_bg_ratio=10
        else
            rmem_max=67108864; wmem_max=67108864; somaxconn=65535; backlog=500000; netdev_budget=1200
            swappiness=10; dirty_ratio=40; dirty_bg_ratio=10
        fi
        
        local qdisc="fq"
        [ "$nic_speed" -lt 1000 ] && qdisc="fq_codel"
        
        echo -e "${Y}[1/5] 优化网络参数...${R}"
        sleep 0.5
        
        {
            echo $swappiness > /proc/sys/vm/swappiness 2>/dev/null || true
            echo 1000 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
            echo $dirty_ratio > /proc/sys/vm/dirty_ratio 2>/dev/null || true
            echo $dirty_bg_ratio > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
            echo $qdisc > /proc/sys/net/core/default_qdisc 2>/dev/null || true
            echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
            echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || true
            echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null || true
            echo 300 > /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null || true
            echo 10 > /proc/sys/net/ipv4/tcp_keepalive_intvl 2>/dev/null || true
            echo 3 > /proc/sys/net/ipv4/tcp_keepalive_probes 2>/dev/null || true
            echo 3 > /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null || true
            echo 131072 > /proc/sys/net/core/rmem_default 2>/dev/null || true
            echo 131072 > /proc/sys/net/core/wmem_default 2>/dev/null || true
            echo $rmem_max > /proc/sys/net/core/rmem_max 2>/dev/null || true
            echo $wmem_max > /proc/sys/net/core/wmem_max 2>/dev/null || true
            echo $backlog > /proc/sys/net/core/netdev_max_backlog 2>/dev/null || true
            echo $somaxconn > /proc/sys/net/core/somaxconn 2>/dev/null || true
            
            modprobe nf_conntrack 2>/dev/null || true
            if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
                echo 1048576 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
                echo 120 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream 2>/dev/null || true
                echo 30 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout 2>/dev/null || true
            fi
            
            [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
            
            if [ -n "$main_nic" ]; then
                tc qdisc replace dev "$main_nic" root "$qdisc" 2>/dev/null || true
                echo 10000 > /sys/class/net/$main_nic/tx_queue_len 2>/dev/null || true
                ethtool -K $main_nic gro on lro on tso on gso on 2>/dev/null || true
            fi
        } &>/dev/null
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[2/5] 优化Swap...${R}"
        sleep 0.3
        check_swap >/dev/null 2>&1
        [ "$mem_mb" -lt 1024 ] && auto_setup_zram >/dev/null 2>&1
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[3/5] 优化Sing-Box (如果已安装)...${R}"
        sleep 0.3
        if command -v "$SB_BIN" >/dev/null 2>&1; then
            if [ -f "$SB_CONF" ] && jq -e . "$SB_CONF" >/dev/null 2>&1; then
                jq '.log.level = "warn"' "$SB_CONF" > "$TMP_DIR/sb_auto.json" && mv "$TMP_DIR/sb_auto.json" "$SB_CONF"
            fi
            if [ -f /etc/systemd/system/sing-box.service ]; then
                local temp_service=$(mktemp)
                cp /etc/systemd/system/sing-box.service "$temp_service"
                if ! grep -q "LimitNOFILE" "$temp_service"; then
                    sed -i '/\[Service\]/a LimitNOFILE=131072\nLimitNPROC=infinity\nNice=-10\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99' "$temp_service" 2>/dev/null || true
                fi
                cp "$temp_service" /etc/systemd/system/sing-box.service
                rm -f "$temp_service"
                systemctl daemon-reload
            fi
        fi
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[4/5] 优化网络流量优先级...${R}"
        sleep 0.3
        for proto in tcp udp; do
            if command -v iptables >/dev/null 2>&1; then
                if ! iptables -t mangle -C OUTPUT -p $proto -j TOS --set-tos Minimize-Delay 2>/dev/null; then
                    iptables -t mangle -A OUTPUT -p $proto -j TOS --set-tos Minimize-Delay 2>/dev/null || true
                fi
            fi
        done
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[5/5] 保存配置...${R}"
        sleep 0.3
        cat > /etc/sysctl.d/99-smart.conf <<EOF
# 智能自动优化配置（整合TikTok直播和低配置优化）
vm.swappiness=$swappiness
vm.dirty_ratio=$dirty_ratio
vm.dirty_background_ratio=$dirty_bg_ratio
vm.dirty_writeback_centisecs=1000
net.core.rmem_default=131072
net.core.wmem_default=131072
net.core.rmem_max=$rmem_max
net.core.wmem_max=$wmem_max
net.core.default_qdisc=$qdisc
net.core.netdev_max_backlog=$backlog
net.core.somaxconn=$somaxconn
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_fin_timeout=3
net.ipv4.ip_local_port_range=1024 65535
net.netfilter.nf_conntrack_max=1048576
net.netfilter.nf_conntrack_udp_timeout_stream=120
net.netfilter.nf_conntrack_udp_timeout=30
EOF
        rm -f /etc/sysctl.d/99-tiktok-udp.conf /etc/sysctl.d/99-bandwidth.conf /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-smart.conf >/dev/null 2>&1
        echo -e "${G}✅ 完成${R}"
        
        echo ""
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "${G}║      🎉 智能优化全部完成！🎉              ║${R}"
        echo -e "${G}╚═══════════════════════════════════════════╝${R}"
        echo ""
        echo -e "${Y}现在您可以：${R}"
        echo -e "  1. 进入Sing-Box管理面板配置代理"
        echo -e "  2. 建议重启服务器获得最佳效果"
        echo ""
        
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
    
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    if [ ! -s "$keyring" ]; then
        echo -e "${RED}❌ XanMod 密钥下载失败！请检查网络或代理设置。${R}"
        return 1
    fi
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
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf /etc/sysctl.d/99-smart.conf /etc/sysctl.d/99-tiktok-live.conf /etc/sysctl.d/99-tiktok-udp.conf /etc/sysctl.d/99-bandwidth.conf /etc/sysctl.d/99-lowprofile-optimize.conf /etc/sysctl.d/99-lowmemory-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
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
    return 0
}
_detect_and_optimize_auto() {
    local mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local cpu_cores=$(nproc 2>/dev/null || echo 1)
    local main_nic=$(ip route | awk '/default/ {print $5; exit}')
    local nic_speed=1000 scene="balanced" mode_name="智能检测"

    if [ -n "$main_nic" ] && command -v ethtool >/dev/null 2>&1; then
        local detected_speed
        detected_speed=$(ethtool "$main_nic" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/, "", $2); print $2; exit}')
        [[ "$detected_speed" =~ ^[0-9]+$ ]] && nic_speed="$detected_speed"
    fi

    if [ "$nic_speed" -le 50 ]; then
        scene="gateway"; mode_name="智能检测-中转网关"
    elif [ "$mem_mb" -lt 1024 ]; then
        scene="balanced"; mode_name="智能检测-低内存均衡"
    elif [ "$mem_mb" -lt 2048 ]; then
        if [ "$nic_speed" -ge 300 ] && [ "$cpu_cores" -ge 2 ]; then
            scene="stream"; mode_name="智能检测-轻量直播"
        else
            scene="balanced"; mode_name="智能检测-通用均衡"
        fi
    elif [ "$mem_mb" -ge 4096 ] && [ "$cpu_cores" -ge 4 ] && [ "$nic_speed" -ge 800 ]; then
        scene="stream_game"; mode_name="智能检测-直播游戏"
    elif [ "$mem_mb" -ge 4096 ] && [ "$cpu_cores" -ge 4 ] && [ "$nic_speed" -ge 300 ]; then
        scene="stream"; mode_name="智能检测-高配直播"
    elif [ "$mem_mb" -ge 2048 ] && [ "$cpu_cores" -ge 2 ]; then
        scene="stream"; mode_name="智能检测-标准直播"
    fi

    echo -e "${Y}检测结果: 内存 ${mem_mb}MB | CPU ${cpu_cores}核 | 网卡 ${nic_speed}Mbps${R}"
    echo -e "${G}自动选择模式: ${mode_name} (${scene})${R}"
    sleep 1
    _kernel_optimize_core "$mode_name" "$scene"
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
        echo -e "    ${Y}🤖 [1] 智能检测与自动优化 (推荐小白)${R}"
        echo -e "    ${H}─────────────────────────────${R}"
        local i=0
        while [ $i -lt 7 ]; do
            local num=$((i + 2)); local scene="${scenes[$i]}"; local name="${names[$i]}"
            if [ "$cur_scene" = "$scene" ]; then echo -e "  ${Y}▶ ${G}[${num}] ${name}  ◀ 当前${R}"
            else echo -e "    ${H}[${num}] ${name}${R}"; fi
            i=$((i + 1))
        done
        echo -e "    ${H}─────────────────────────────${R}"
        echo -e "    ${H}[9] 还原默认  [10] 远程脚本  [11] 释放缓存  [12] 验证状态  [0] 返回${R}"
        echo ""
        read -e -p "  选择: " c
        case $c in
            1) clear; _detect_and_optimize_auto ;;
            2) clear; _kernel_optimize_core "直播+游戏" "stream_game" ;; 3) clear; _kernel_optimize_core "高性能" "high" ;;
            4) clear; _kernel_optimize_core "均衡" "balanced" ;; 5) clear; _kernel_optimize_core "网站" "web" ;;
            6) clear; _kernel_optimize_core "直播" "stream" ;; 7) clear; _kernel_optimize_core "游戏" "game" ;;
            8) clear; _kernel_optimize_core "网关" "gateway" ;; 9) clear; restore_defaults ;;
            10) curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;;
            11) read -e -p "确定释放缓存？: " d; [[ "$d" =~ ^[Yy]$ ]] && sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null ;;
            12) verify_network_status ;; 0|"") break ;;
        esac
    done
}

# ================= 顶级大厂域名优选模块 (3x-ui 官方完整版 37域名) =================
SNI_DOMAINS=(
    "google-analytics.com" "www.microsoft.com" "www.cloudflare.com" "www.amazon.com" "www.apple.com" "www.bing.com"
    "www.yahoo.com" "www.icloud.com" "www.office.com" "aws.amazon.com" "azure.microsoft.com" "dl.google.com"
    "cdn.apple.com" "api.apple.com" "init.push.apple.com" "www.sony.com" "www.oracle.com" "www.ibm.com"
    "www.nvidia.com" "images.nvidia.com" "www.intel.com" "www.amd.com" "www.ebay.com" "www.paypal.com"
    "www.tesla.com" "www.mozilla.org" "www.lovelive-anime.jp" "www.cisco.com" "www.sap.com" "www.samsung.com"
    "www.huawei.com" "www.dell.com" "www.hp.com" "www.canva.com" "www.cdn77.org" "www.fastly.com"
    "www.akamai.com" "www.digitalocean.com"
)
CDN_DOMAINS=(
    "visa.com.sg" "www.visa.com" "www.bing.com" "www.microsoft.com" "www.icloud.com" "www.apple.com"
    "www.amazon.com" "www.tesla.com" "dash.cloudflare.com"
)

_test_domain_latency() {
    local domain="$1" result_file="$2"
    # 错峰并发：随机休眠 0~0.9 秒，彻底错开并发，防防火墙拦截
    sleep 0.$(( RANDOM % 10 ))
    # 严格强制 TLS 1.3，恢复 time_appconnect 握手时间测速，完全对齐 3x-ui 验证标准
    local time_appconnect=$(curl -4 -s --tlsv1.3 -o /dev/null --connect-timeout 2 --max-time 4 -w "%{time_appconnect}" "https://${domain}" 2>/dev/null)
    if [[ "$time_appconnect" =~ ^[0-9]+(\.[0-9]+)?$ && "$time_appconnect" != "0.000000" ]]; then
        local ms=$(awk "BEGIN{printf \"%.0f\", ${time_appconnect}*1000}")
        echo "${ms} ${domain}" >> "$result_file"
    else
        echo "9999 ${domain}" >> "$result_file"
    fi
}

select_best_domain() {
    local mode="${1:-sni}" user_host="${2:-}"
    local domains=() purpose=""
    if [ "$mode" = "cdn" ]; then domains=("${CDN_DOMAINS[@]}"); purpose="Cloudflare CDN 大厂代理节点优选"
    else domains=("${SNI_DOMAINS[@]}"); purpose="大厂 SNI (TLS 偷步) 优选"; fi
    
    while true; do
        clear >&2
        echo -e "${G}╔══════════════════════════════════════╗${R}" >&2
        echo -e "${G}║       顶级大厂域名优选模块            ║${R}" >&2
        echo -e "${G}╚══════════════════════════════════════╝${R}" >&2
        echo -e "当前用途: ${Y}${purpose}${R}" >&2
        echo "" >&2
        echo -e "${C}1.${R} 自动并发测速优选 (推荐)" >&2
        echo -e "${C}2.${R} 手动输入域名" >&2
        echo -e "${C}3.${R} 使用默认域名 (google-analytics.com)" >&2
        echo -e "${H}0.${R} 返回上层" >&2
        echo "" >&2
        read -e -p "请选择 [1-3]: " choice
        case "$choice" in
            1)
                echo -e "${Y}[*] 正在并发测试 ${#domains[@]} 个大厂域名...${R}" >&2
                local tmp_res="$TMP_DIR/sb_domain_speed"
                > "$tmp_res"
                for domain in "${domains[@]}"; do _test_domain_latency "$domain" "$tmp_res" & done
                
                local total=${#domains[@]}
                while true; do
                    local done_count; done_count=$(wc -l < "$tmp_res" 2>/dev/null || echo 0)
                    [ "$((total - done_count))" -le 0 ] && break
                    sleep 0.2
                done
                wait 
                echo -e "\n${G}✅ 测速完成！${R}" >&2
                
                local sorted_domains=$(grep -v "^9999" "$tmp_res" | sort -n)
                rm -f "$tmp_res"
                if [ -z "$sorted_domains" ]; then 
                    echo -e "${RED}❌ 所有域名测速失败！可能是服务器网络异常，请尝试手动输入。${R}" >&2
                    read -rs -n 1 -p "按任意键继续..." >&2
                    continue
                fi
                
                echo -e "${G}-----------------------------------------${R}" >&2
                local top_domains=() i=1
                while IFS= read -r line; do
                    local latency=$(echo "$line" | awk '{print $1}')
                    local dom=$(echo "$line" | awk '{print $2}')
                    printf "  ${G}[%d]${R} %-30s ${Y}%s ms${R}\n" "$i" "$dom" "$latency" >&2
                    top_domains+=("$dom"); i=$((i+1))
                    [ $i -gt 5 ] && break
                done <<< "$sorted_domains"
                echo -e "${G}-----------------------------------------${R}" >&2
                
                read -e -p "请输入序号选用 [1-5, 默认1]: " sel
                sel=$(echo "$sel" | tr -d '[:space:]')
                [ -z "$sel" ] && sel=1
                if [[ "$sel" =~ ^[1-5]$ ]] && [ ${#top_domains[@]} -ge $sel ]; then
                    echo "${top_domains[$((sel-1))]}"
                    return 0
                else echo -e "${RED}选择无效${R}" >&2; sleep 1; fi
                ;;
            2) 
                read -e -p "请输入域名 (如 www.example.com): " manual_dom
                manual_dom=$(echo "$manual_dom" | tr -d '[:space:]')
                if [ -n "$manual_dom" ]; then echo "$manual_dom"; return 0; fi 
                ;;
            3) echo "google-analytics.com"; return 0 ;;
            0|"") return 1 ;;
        esac
    done
}

# ================= Sing-Box 核心 (强制自愈与对齐 3x-ui 版) =================
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/.nodes_meta"

get_my_ip() { 
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done
    if [ -z "$server_ip" ]; then
        server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
    fi
    [ -z "$server_ip" ] && server_ip="服务器IP"
    echo "$server_ip"
}

force_sync_time() {
    echo -e "${Y}[*] 正在校准系统时间 (Reality 协议对时间极其敏感)...${R}"
    command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1
    local current_year=$(date +%Y)
    if [ "$current_year" -lt 2020 ] || [ "$current_year" -gt 2030 ]; then
        echo -e "${Y}检测到系统时间异常($current_year)，正在通过 HTTP 强制校准...${R}"
        local sys_time=$(curl -sI https://www.cloudflare.com 2>/dev/null | grep -i '^date:' | sed 's/^[Dd]ate: //g' | tr -d '\r')
        if [ -n "$sys_time" ]; then
            date -s "$sys_time" >/dev/null 2>&1
            echo -e "${G}✅ 系统时间已强制校准至: $(date)${R}"
        else
            echo -e "${RED}⚠ HTTP 校准失败，请确保服务器时间正确，否则 Reality 节点将无法连通！${R}"
        fi
    else
        echo -e "${G}✅ 系统时间正常: $(date)${R}"
    fi
}

url_encode() { jq -rn --arg v "$1" '$v|@uri' | sed 's/%2F/\//g'; }

check_port_occupied() {
    local port=$1
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then return 1; fi
    if ss -tunlpn | awk '{print $5}' | grep -qE ":${port}\$"; then return 0; else return 1; fi
}

sb_check() { 
    if ! command -v $SB_BIN >/dev/null 2>&1; then 
        echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return 1; 
    fi
    
    local need_reset=0
    if [ ! -s "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1; then
        need_reset=1
    else
        if ! $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
            need_reset=1
        fi
    fi

    if [ "$need_reset" -eq 1 ]; then
        echo -e "${Y}检测到配置文件损坏或校验失败，正在强制重置为初始状态...${R}"
        mv "$SB_CONF" "${SB_CONF}.corrupted.$(date +%s)" 2>/dev/null
        sb_init_conf
        systemctl restart sing-box >/dev/null 2>&1
    fi

    if [ -f "$SB_CONF" ] && command -v jq >/dev/null 2>&1; then
        local tmp_clean="$TMP_DIR/sb_clean.json"
        if jq 'del(.dns.cache_size) | (.inbounds[]? |= del(.packet_encoding)) | (.inbounds[]? | select(.tls.reality != null) |= del(.tls.min_version, .tls.alpn, .tls.cipher_suites))' "$SB_CONF" > "$tmp_clean" 2>/dev/null; then
            if [ -s "$tmp_clean" ]; then
                if ! cmp -s "$SB_CONF" "$tmp_clean"; then
                    if $SB_BIN check -c "$tmp_clean" >/dev/null 2>&1; then
                        mv -f "$tmp_clean" "$SB_CONF"
                        systemctl restart sing-box >/dev/null 2>&1
                        echo -e "${Y}已自动深度清理不兼容字段并重启服务！${R}"
                        sleep 1
                    else
                        rm -f "$tmp_clean"
                    fi
                else
                    rm -f "$tmp_clean"
                fi
            else
                rm -f "$tmp_clean"
            fi
        fi
    fi
    return 0
}

sb_init_conf() { 
    if [ ! -f "$SB_CONF" ] || [ ! -s "$SB_CONF" ]; then 
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","auto_detect_interface":true}}' > "$SB_CONF"
    elif ! jq -e . "$SB_CONF" >/dev/null 2>&1; then
        echo -e "${RED}警告：$SB_CONF 文件损坏，已自动备份至 ${SB_CONF}.corrupted${R}"
        mv "$SB_CONF" "${SB_CONF}.corrupted"
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","auto_detect_interface":true}}' > "$SB_CONF"
    fi
}

_init_meta_file() { 
    if [ ! -f "$META_FILE" ]; then 
        mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"; chmod 600 "$META_FILE"
    elif ! jq -e . "$META_FILE" >/dev/null 2>&1; then
        mv "$META_FILE" "${META_FILE}.corrupted"
        echo '{}' > "$META_FILE"; chmod 600 "$META_FILE"
    fi
}

_save_node_meta() {
    _init_meta_file; local tmp="$TMP_DIR/sb_meta.json"
    if [ -n "$4" ]; then jq --arg p "$1" --arg n "$2" --arg t "$3" --arg pk "$4" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "pub_key": $pk, "extra": $ex}' "$META_FILE" > "$tmp"
    else jq --arg p "$1" --arg n "$2" --arg t "$3" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "extra": $ex}' "$META_FILE" > "$tmp"; fi
    [ -s "$tmp" ] && { mv -f "$tmp" "$META_FILE"; chmod 600 "$META_FILE"; } || rm -f "$tmp"
}

_del_node_meta() { _init_meta_file; jq --arg p "$1" 'del(.[$p])' "$META_FILE" > "$TMP_DIR/sb_meta.json" && mv "$TMP_DIR/sb_meta.json" "$META_FILE"; }
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
    
    local exec_lines=""
    if [ -n "$ipt_rest" ]; then exec_lines="ExecStart=$ipt_rest /etc/iptables.rules"; fi
    if [ -n "$ip6t_rest" ]; then exec_lines="${exec_lines}\nExecStart=$ip6t_rest /etc/ip6tables.rules"; fi
    
    if [ -n "$exec_lines" ]; then
        printf "[Unit]\nDescription=Restore iptables rules for Sing-Box\nAfter=network-pre.target\nBefore=network.target\n[Service]\nType=oneshot\n%s\nRemainAfterExit=yes\n[Install]\nWantedBy=multi-user.target\n" "$exec_lines" > /etc/systemd/system/sb-iptables.service
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sb-iptables.service >/dev/null 2>&1
    fi
}

sb_install() {
    if command -v $SB_BIN >/dev/null 2>&1; then echo -e "${Y}Sing-Box 已安装！${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) echo -e "${RED}❌ 不支持 ${arch}${R}"; return 1;; esac
    echo -e "${Y}即将安装 Sing-Box (${arch})${R}"; read -e -p "继续？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    local latest_ver=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//')
    [ -z "$latest_ver" ] && latest_ver="1.10.7"
    mkdir -p /etc/sing-box
    if curl -L -o "$TMP_DIR/sb.tar.gz" -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz" 2>/dev/null; then
        if tar xzf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" 2>/dev/null; then
            local tmp_bin="$TMP_DIR/sing-box-new"
            mv "$TMP_DIR/sing-box-${latest_ver}-linux-${arch}/sing-box" "$tmp_bin" 2>/dev/null
            rm -rf "$TMP_DIR/sb.tar.gz" "$TMP_DIR/sing-box-${latest_ver}-linux-${arch}"
            chmod +x "$tmp_bin"
            if "$tmp_bin" version >/dev/null 2>&1; then
                mv -f "$tmp_bin" $SB_BIN
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
            else
                echo -e "${RED}❌ 下载的执行文件无法运行，可能架构不匹配或文件损坏！${R}"
                rm -f "$tmp_bin"
            fi
        else
            echo -e "${RED}❌ 解压失败，可能是 GitHub 限流返回了 HTML 错误页。${R}"
            rm -f "$TMP_DIR/sb.tar.gz"
        fi
    else echo -e "${RED}❌ 下载失败${R}"; fi
    read -rs -n 1 -p ""
}

sb_update() {
    if ! command -v $SB_BIN >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) return 1;; esac
    local latest_ver=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//')
    [ -z "$latest_ver" ] && latest_ver="1.10.7"
    echo -e "${Y}正在更新 Sing-Box...${R}"
    if curl -L -o "$TMP_DIR/sb.tar.gz" -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz" 2>/dev/null; then
        if tar xzf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" 2>/dev/null; then
            local tmp_bin="$TMP_DIR/sing-box-new"
            mv "$TMP_DIR/sing-box-${latest_ver}-linux-${arch}/sing-box" "$tmp_bin" 2>/dev/null
            rm -rf "$TMP_DIR/sb.tar.gz" "$TMP_DIR/sing-box-${latest_ver}-linux-${arch}"
            chmod +x "$tmp_bin"
            if "$tmp_bin" version >/dev/null 2>&1; then
                systemctl stop sing-box >/dev/null 2>&1
                mv -f "$tmp_bin" $SB_BIN
                systemctl start sing-box >/dev/null 2>&1
                echo -e "${G}✅ 更新成功 | 版本: $($SB_BIN version 2>/dev/null | head -1)${R}"
            else
                echo -e "${RED}❌ 新版执行文件验证失败，可能架构不匹配。更新已取消，旧版本不受影响。${R}"
                rm -f "$tmp_bin"
            fi
        else
            echo -e "${RED}❌ 解压失败，可能是 GitHub 限流返回了 HTML 错误页。${R}"
        fi
    else echo -e "${RED}❌ 下载失败${R}"; fi
    read -rs -n 1 -p ""
}

sb_uninstall() {
    if ! command -v $SB_BIN >/dev/null 2>&1; then echo -e "${Y}Sing-Box 未安装${R}"; read -rs -n 1 -p ""; return; fi
    read -e -p "确认卸载？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    systemctl stop sing-box sb-iptables >/dev/null 2>&1
    systemctl disable sing-box sb-iptables >/dev/null 2>&1
    rm -rf /etc/sing-box $SB_BIN /etc/systemd/system/sing-box.service /etc/systemd/system/sb-iptables.service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
    echo -e "${G}✅ Sing-Box 已完全卸载${R}"; read -rs -n 1 -p ""
}

sb_view_log() {
    echo -e "${Y}退出日志请按 Ctrl+C${R}"
    trap - INT
    timeout 3600 journalctl -u sing-box -f -n 50
    trap 'rm -rf "$TMP_DIR" 2>/dev/null; exit 130' INT
}

_wait_for_sb_active() {
    local i=0
    while [ $i -lt 30 ]; do
        if systemctl is-active --quiet sing-box 2>/dev/null; then return 0; fi
        sleep 0.5; i=$((i+1))
    done
    return 1
}

_get_port() {
    local port=$1; local input_port
    while true; do
        echo -e "${Y}提示：如果云服务器有安全组限制，请输入已在安全组放行的端口${R}" >&2
        echo -e "${Y}提示：建议使用随机高位端口(如 10000-65535) 避免被封！${R}" >&2
        read -e -p "端口 (回车默认随机 $port): " input_port
        input_port=$(echo "$input_port" | tr -d '[:space:]')
        if [[ "$input_port" =~ ^[0-9]{1,5}$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
            port="$input_port"
        elif [ -n "$input_port" ]; then
            echo -e "${RED}❌ 端口范围必须在 1-65535 之间！${R}" >&2; continue
        fi
        if check_port_occupied "$port"; then echo -e "${RED}❌ 端口 $port 已被占用，请重新输入！${R}" >&2; else break; fi
    done
    echo "$port"
}

sb_add_reality() {
    sb_check || return
    force_sync_time
    
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    port=$(echo "$port" | tr -d '[:space:]')
    
    local sni; sni=$(select_best_domain "sni")
    sni=$(echo "$sni" | tr -d '[:space:]')
    [ -z "$sni" ] && { echo -e "${Y}已取消添加。${R}"; return; }
    
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local keys_output priv_key pub_key; keys_output=$($SB_BIN generate reality-keypair 2>&1)
    priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}' | tr -d '\r'); pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}' | tr -d '\r')
    
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        echo -e "${RED}密钥生成失败${R}"; return
    fi
    
    local short_id=$($SB_BIN generate rand --hex 8 2>/dev/null || echo "aabbccdd")
    local nn; read -e -p "名称 (回车默认): " nn
    nn=$(echo "$nn" | tr -d '\r')
    [ -z "$nn" ] && nn="VLESS-Reality-${port}"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    
    # 修复：补全 alpn 参数，完全对齐 3x-ui 的配置结构
    jq --arg p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" \
       '.inbounds += [{
           "type": "vless",
           "tag": ("vless-reality-"+($p|tostring)),
           "listen": "::",
           "listen_port": ($p|tonumber),
           "users": [{"uuid": $u, "flow": "xtls-rprx-vision"}],
           "tls": {
               "enabled": true,
               "server_name": $s,
               "alpn": ["h2", "http/1.1"],
               "reality": {
                   "enabled": true,
                   "handshake": {"server": $s, "server_port": 443},
                   "private_key": $pk,
                   "short_id": [$sid]
               }
           }
       }]' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    
    local check_err
    if check_err=$($SB_BIN check -c "$SB_CONF" 2>&1); then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-reality" "$pub_key" "short_id=${short_id};sni=${sni}"
        systemctl restart sing-box
        if _wait_for_sb_active; then 
            echo -e "${G}✅ VLESS-Reality 部署成功！${R}"
            echo -e "${G}🔑 PublicKey: ${pub_key}${R}"
            local server_ip=$(get_my_ip); local server_ip_url="$server_ip"
            if [[ "$server_ip" =~ : ]]; then server_ip_url="[$server_ip]"; fi
            
            # 修复：链接格式对齐 3x-ui，加入 spx，去掉 headerType
            local spx_path="%2F$(openssl rand -hex 8)"
            local link="vless://${uuid}@${server_ip_url}:${port}?encryption=none&flow=xtls-rprx-vision&fp=chrome&pbk=${pub_key}&security=reality&sid=${short_id}&sni=${sni}&spx=${spx_path}&type=tcp#$(url_encode "$nn")"
            
            echo -e "${C}节点链接: ${link}${R}"
            _persist_iptables; 
        else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
            del_port_both "$port"; _del_node_meta "$port"
        fi
    else 
        echo -e "${RED}校验失败: ${check_err}${R}"
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
        _del_node_meta "$port"
    fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_vless_ws() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    port=$(echo "$port" | tr -d '[:space:]')
    local ws_path="/$(openssl rand -hex 8)"; read -e -p "WS Path (回车默认): " wp
    if [ -n "$wp" ]; then
        wp=$(echo "$wp" | tr -d '\r')
        [[ "$wp" != /* ]] && wp="/$wp"
        ws_path="$wp"
    fi
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local nn; read -e -p "名称 (回车默认): " nn
    nn=$(echo "$nn" | tr -d '\r')
    [ -z "$nn" ] && nn="VLESS-WS-${port}"
    
    local cdn_yn cdn_domain cdn_host=""
    read -e -p "是否启用大厂 CDN 并发测速优选？[y/N]: " cdn_yn
    if [[ "$cdn_yn" =~ ^[Yy]$ ]]; then
        read -e -p "请输入你已解析到 Cloudflare 的域名: " cdn_host
        cdn_host=$(echo "$cdn_host" | tr -d '[:space:]')
        if [ -n "$cdn_host" ]; then
            cdn_domain=$(select_best_domain "cdn" "$cdn_host")
            cdn_domain=$(echo "$cdn_domain" | tr -d '[:space:]')
            [ -z "$cdn_domain" ] && cdn_domain=""
        else
            echo -e "${RED}必须输入域名才能使用 CDN，已自动取消 CDN${R}"
        fi
    fi

    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    
    jq --arg p "$port" --arg u "$uuid" --arg wp "$ws_path" \
       '.inbounds += [{
           "type": "vless",
           "tag": ("vless-ws-"+($p|tostring)),
           "listen": "::",
           "listen_port": ($p|tonumber),
           "users": [{"uuid": $u}],
           "transport": {"type": "ws", "path": $wp}
       }]' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    
    local check_err
    if check_err=$($SB_BIN check -c "$SB_CONF" 2>&1); then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-ws" "" "path=${ws_path};cdn_server=${cdn_domain};cdn_host=${cdn_host}"
        systemctl restart sing-box
        if _wait_for_sb_active; then 
            echo -e "${G}✅ 成功 | Path: ${ws_path} | CDN: ${cdn_domain:-未启用}${R}"
            local server_ip=$(get_my_ip); local server_ip_url="$server_ip"
            if [[ "$server_ip" =~ : ]]; then server_ip_url="[$server_ip]"; fi
            local client_server="$server_ip_url"; local link_host_param=""
            if [ -n "$cdn_domain" ] && [ -n "$cdn_host" ]; then
                client_server="$cdn_domain"; link_host_param="&host=$(url_encode "$cdn_host")"
            fi
            local link="vless://${uuid}@${client_server}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path:-/}")${link_host_param}#$(url_encode "$nn")"
            echo -e "${C}节点链接: ${link}${R}"
            _persist_iptables; 
        else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
            del_port_both "$port"; _del_node_meta "$port"
        fi
    else 
        echo -e "${RED}校验失败: ${check_err}${R}"
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
        _del_node_meta "$port"
    fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_hysteria2() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    port=$(echo "$port" | tr -d '[:space:]')
    local pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local nn; read -e -p "名称 (回车默认): " nn
    nn=$(echo "$nn" | tr -d '\r')
    [ -z "$nn" ] && nn="Hysteria2-TikTok-${port}"
    
    local sni; sni=$(select_best_domain "sni")
    sni=$(echo "$sni" | tr -d '[:space:]')
    [ -z "$sni" ] && { echo -e "${Y}已取消添加。${R}"; return; }
    
    local cert_dir="/etc/sing-box/certs/hy2-${port}"; mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=${sni}" 2>/dev/null
    chmod 600 "${cert_dir}/key.pem"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    
    jq --arg p "$port" --arg pass "$pass" --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" --arg s "$sni" \
       '.inbounds += [{
           "type": "hysteria2",
           "tag": ("hysteria2-"+($p|tostring)),
           "listen": "::",
           "listen_port": ($p|tonumber),
           "users": [{"password": $pass}],
           "tls": {
               "enabled": true,
               "server_name": $s,
               "alpn": ["h3", "h2", "http/1.1"],
               "min_version": "1.2",
               "certificate_path": $c,
               "key_path": $k
           },
           "congestion_control": "bbr",
           "udp_disable_fragment": false,
           "ignore_client_bandwidth": true,
           "disable_mtu_discovery": false
       }]' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    
    local check_err
    if check_err=$($SB_BIN check -c "$SB_CONF" 2>&1); then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "hysteria2" "" "password=${pass};tls_method=selfsign;sni=${sni};tiktok_optimized=true"
        systemctl restart sing-box
        if _wait_for_sb_active; then 
            echo -e "${G}✅ TikTok直播专用Hysteria2部署成功！${R}"
            echo -e "${G}🔑 密码: ${pass}${R}"
            local server_ip=$(get_my_ip); local server_ip_url="$server_ip"
            if [[ "$server_ip" =~ : ]]; then server_ip_url="[$server_ip]"; fi
            local link="hysteria2://$(url_encode "$pass")@${server_ip_url}:${port}?insecure=1&alpn=h3&sni=${sni}#$(url_encode "$nn")"
            echo -e "${C}节点链接: ${link}${R}"
            _persist_iptables; 
        else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
            del_port_both "$port"; _del_node_meta "$port"; rm -rf "$cert_dir"
        fi
    else 
        echo -e "${RED}校验失败: ${check_err}${R}"
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
        _del_node_meta "$port"; rm -rf "$cert_dir"
    fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_add_tuic() {
    sb_check || return
    local port; port=$(_get_port $(shuf -i 10000-65535 -n 1))
    port=$(echo "$port" | tr -d '[:space:]')
    local uuid=$($SB_BIN generate uuid 2>/dev/null)
    local pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
    local nn; read -e -p "名称 (回车默认): " nn
    nn=$(echo "$nn" | tr -d '\r')
    [ -z "$nn" ] && nn="TUIC-TikTok-${port}"
    
    local sni; sni=$(select_best_domain "sni")
    sni=$(echo "$sni" | tr -d '[:space:]')
    [ -z "$sni" ] && { echo -e "${Y}已取消添加。${R}"; return; }
    
    local cert_dir="/etc/sing-box/certs/tuic-${port}"; mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=${sni}" 2>/dev/null
    chmod 600 "${cert_dir}/key.pem"
    
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    
    jq --arg p "$port" --arg u "$uuid" --arg pass "$pass" --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" --arg s "$sni" \
       '.inbounds += [{
           "type": "tuic",
           "tag": ("tuic-"+($p|tostring)),
           "listen": "::",
           "listen_port": ($p|tonumber),
           "users": [{"uuid": $u, "password": $pass}],
           "congestion_control": "bbr",
           "udp_relay_mode": "native",
           "tls": {
               "enabled": true,
               "server_name": $s,
               "alpn": ["h3", "h2", "http/1.1"],
               "min_version": "1.2",
               "certificate_path": $c,
               "key_path": $k
           }
       }]' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    
    local check_err
    if check_err=$($SB_BIN check -c "$SB_CONF" 2>&1); then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "tuic" "" "uuid=${uuid};password=${pass};tls_method=selfsign;sni=${sni};tiktok_optimized=true"
        systemctl restart sing-box
        if _wait_for_sb_active; then 
            echo -e "${G}✅ TikTok优化版TUIC部署成功！${R}"
            echo -e "${G}UUID: ${uuid}${R}"
            echo -e "${G}密码: ${pass}${R}"
            local server_ip=$(get_my_ip); local server_ip_url="$server_ip"
            if [[ "$server_ip" =~ : ]]; then server_ip_url="[$server_ip]"; fi
            local link="tuic://${uuid}:$(url_encode "$pass")@${server_ip_url}:${port}?congestion_control=bbr&alpn=h3&sni=${sni}&allow_insecure=1#$(url_encode "$nn")"
            echo -e "${C}节点链接: ${link}${R}"
            _persist_iptables; 
        else
            echo -e "${RED}启动失败${R}"; local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
            del_port_both "$port"; _del_node_meta "$port"; rm -rf "$cert_dir"
        fi
    else 
        echo -e "${RED}校验失败: ${check_err}${R}"
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
        _del_node_meta "$port"; rm -rf "$cert_dir"
    fi
    _clean_bak; read -rs -n 1 -p ""
}

sb_show_nodes_and_links() {
    sb_check || return
    local server_ip=$(get_my_ip)
    local server_ip_url="$server_ip"
    if [[ "$server_ip" =~ : ]]; then server_ip_url="[$server_ip]"; fi
    echo -e "\n${Y}===== 节点列表与链接 =====${R}\n${H}服务器地址: ${server_ip}${R}\n"
    local idx=1 has_any=0
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port inb_type nn ex link=""
        port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        
        inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        nn=$(_get_node_meta "$port" "name")
        [ -z "$nn" ] && nn="${inb_type}-${port}"
        ex=$(_get_node_meta "$port" "extra")
        echo -e "${G}━━━ [${idx}] ${inb_type^^} | 端口: ${port} | ${nn} ━━━${R}"; has_any=1
        
        case "$inb_type" in
            vless)
                local uuid flow sni pub_key short_id ws_path cdn_server cdn_host
                uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                if echo "$obj" | jq -e '.tls.reality' >/dev/null 2>&1; then
                    sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                    pub_key=$(_get_node_meta "$port" "pub_key")
                    short_id=$(echo "$ex" | sed -n 's/.*short_id=\([^;]*\).*/\1/p')
                    [ -z "$short_id" ] && short_id=$(echo "$obj" | jq -r '.tls.reality.short_id[0] // empty' 2>/dev/null)
                    flow=$(echo "$obj" | jq -r '.users[0].flow // empty' 2>/dev/null)
                    local flow_param=""; [ -n "$flow" ] && flow_param="&flow=${flow}"
                    if [ -n "$pub_key" ]; then
                        link="vless://${uuid}@${server_ip_url}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#$(url_encode "$nn")"
                    else
                        link="${RED}无法生成链接：缺少 PublicKey${R}"
                    fi
                else
                    ws_path=$(echo "$ex" | sed -n 's/.*path=\([^;]*\).*/\1/p')
                    [ -z "$ws_path" ] && ws_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null)
                    cdn_server=$(echo "$ex" | sed -n 's/.*cdn_server=\([^;]*\).*/\1/p')
                    cdn_host=$(echo "$ex" | sed -n 's/.*cdn_host=\([^;]*\).*/\1/p')
                    local client_server="$server_ip_url"
                    local link_host_param=""
                    if [ -n "$cdn_server" ] && [ -n "$cdn_host" ]; then
                        client_server="$cdn_server"
                        link_host_param="&host=$(url_encode "$cdn_host")"
                    fi
                    link="vless://${uuid}@${client_server}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path:-/}")${link_host_param}#$(url_encode "$nn")"
                fi ;;
            hysteria2)
                local pass sni
                pass=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p')
                [ -z "$pass" ] && pass=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                sni=$(echo "$ex" | sed -n 's/.*sni=\([^;]*\).*/\1/p')
                [ -z "$sni" ] && sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                [ -z "$sni" ] && sni="www.bing.com"
                link="hysteria2://$(url_encode "$pass")@${server_ip_url}:${port}?insecure=1&alpn=h3&sni=${sni}#$(url_encode "$nn")" ;;
            tuic)
                local uuid pass sni
                uuid=$(echo "$ex" | sed -n 's/.*uuid=\([^;]*\).*/\1/p')
                [ -z "$uuid" ] && uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                pass=$(echo "$ex" | sed -n 's/.*password=\([^;]*\).*/\1/p')
                [ -z "$pass" ] && pass=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                sni=$(echo "$ex" | sed -n 's/.*sni=\([^;]*\).*/\1/p')
                [ -z "$sni" ] && sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                [ -z "$sni" ] && sni="www.bing.com"
                link="tuic://${uuid}:$(url_encode "$pass")@${server_ip_url}:${port}?congestion_control=bbr&alpn=h3&sni=${sni}&allow_insecure=1#$(url_encode "$nn")" ;;
        esac
        [ -n "$link" ] && echo -e "${C}${link}${R}\n"
        idx=$((idx + 1))
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
        local port inb_type nn ex
        port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        nn=$(_get_node_meta "$port" "name")
        [ -z "$nn" ] && nn="${inb_type}-${port}"
        echo -e "${G}━━━ [${idx}] ${inb_type^^} | 端口: ${port} | ${nn} ━━━${R}"
        idx=$((idx + 1)); has_any=1
    done < <(jq -r '.inbounds[] | @base64' "$SB_CONF" 2>/dev/null)
    
    [ "$has_any" -eq 0 ] && { echo -e "${Y}无节点可删除${R}"; read -rs -n 1 -p ""; return; }
    
    read -e -p "请输入要删除的端口号: " del_input
    del_input=$(echo "$del_input" | tr -d '[:space:]')
    [ -z "$del_input" ] || [[ "$del_input" == "0" ]] && return
    
    local found_tag=$(jq -r --arg p "$del_input" '.inbounds[] | select(.listen_port == ($p|tonumber)) | .tag' "$SB_CONF" 2>/dev/null | head -1)
    [ -z "$found_tag" ] && { echo -e "${RED}未找到节点${R}"; return; }
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    jq --arg t "$found_tag" 'del(.inbounds[] | select(.tag == $t))' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    
    local check_err
    if check_err=$($SB_BIN check -c "$SB_CONF" 2>&1); then
        _del_node_meta "$del_input"; systemctl restart sing-box
        del_port_both "$del_input"
        rm -rf /etc/sing-box/certs/hy2-${del_input} /etc/sing-box/certs/tuic-${del_input}
        _persist_iptables
        echo -e "${G}✅ 已删除并清理残留${R}"
    else 
        echo -e "${RED}校验失败: ${check_err}${R}"
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
    fi
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
            1) 
               read -e -p "请输入端口号 (1-65535): " port
               port=$(echo "$port" | tr -d '[:space:]')
               if [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
                   open_port_both "$port"; _persist_iptables
               else
                   echo -e "${RED}❌ 端口输入错误！${R}"
               fi
               read -rs -n 1 -p "按任意键继续..." ;;
            2) 
               read -e -p "起始端口 (1-65535): " sp
               read -e -p "结束端口 (1-65535): " ep
               sp=$(echo "$sp" | tr -d '[:space:]'); ep=$(echo "$ep" | tr -d '[:space:]')
               if [[ "$sp" =~ ^[0-9]{1,5}$ ]] && [[ "$ep" =~ ^[0-9]{1,5}$ ]] && [ "$sp" -ge 1 ] && [ "$ep" -le 65535 ] && [ "$sp" -le "$ep" ]; then
                   if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
                       ufw allow ${sp}:${ep}/tcp >/dev/null 2>&1; ufw allow ${sp}:${ep}/udp >/dev/null 2>&1
                   elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
                       firewall-cmd --permanent --add-port=${sp}:${ep}/tcp >/dev/null 2>&1
                       firewall-cmd --permanent --add-port=${sp}:${ep}/udp >/dev/null 2>&1
                       firewall-cmd --reload >/dev/null 2>&1
                   elif command -v iptables >/dev/null 2>&1; then
                       iptables -I INPUT -p tcp --dport ${sp}:${ep} -j ACCEPT 2>/dev/null
                       iptables -I INPUT -p udp --dport ${sp}:${ep} -j ACCEPT 2>/dev/null
                       command -v ip6tables >/dev/null 2>&1 && {
                           ip6tables -I INPUT -p tcp --dport ${sp}:${ep} -j ACCEPT 2>/dev/null
                           ip6tables -I INPUT -p udp --dport ${sp}:${ep} -j ACCEPT 2>/dev/null
                       }
                   fi
                   echo -e "${G}  ✅ 已放行端口范围 ${sp}-${ep} (TCP+UDP)${R}"
                   _persist_iptables
               else
                   echo -e "${RED}❌ 端口范围输入错误！${R}"
               fi
               read -rs -n 1 -p "按任意键继续..." ;;
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
        echo -e "${Y}🎯 TikTok专用 - 性能与安全平衡${R}"
        echo -e "${G}[1] 添加 VLESS-Reality ⭐⭐⭐⭐⭐ (安全首选)${R}"
        echo -e "   ${H}大厂SNI伪装，TLS指纹完美，封号风险最低${R}"
        echo -e "${G}[2] 添加 Hysteria2 ⭐⭐⭐⭐ (性能首选)${R}"
        echo -e "   ${H}QUIC+UDP，直播性能最强，但需注意风控${R}"
        echo -e "${G}[3] 添加 TUIC v5 ⭐⭐⭐ (备选)${R}"
        echo -e "   ${H}纯UDP协议，游戏/直播优化${R}"
        echo -e "${H}────────────────────────${R}"
        echo -e "${H}[4] 添加 VLESS-WS (不推荐用于直播)${R}"
        echo -e "${H}────────────────────────${R}"
        echo -e "${H}[5] 查看节点与链接${R}"
        echo -e "${H}[6] 删除节点${R}"
        echo -e "${H}────────────────────────${R}"
        echo -e "${H}[7] 安装 Sing-Box${R}"
        echo -e "${H}[8] 更新 Sing-Box${R}"
        echo -e "${H}[9] 卸载 Sing-Box${R}"
        echo -e "${H}[10] 重启 Sing-Box${R}"
        echo -e "${H}[11] 查看 Sing-Box 日志${R}"
        echo -e "${H}[12] 手动开放端口${R}"
        echo ""
        echo -e "${H}[0] 返回主菜单${R}"
        echo ""
        echo -e "${Y}⚠️ 专家警示：TikTok风控严格，优先用VLESS-Reality！${R}"
        read -e -p "  选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; sb_add_reality ;; 2) clear; sb_add_hysteria2 ;;
            3) clear; sb_add_tuic ;; 4) clear; sb_add_vless_ws ;;
            5) clear; sb_show_nodes_and_links ;; 6) clear; sb_del_node ;;
            7) clear; sb_install ;; 8) clear; sb_update ;; 9) clear; sb_uninstall ;;
            10) clear; systemctl restart sing-box && echo -e "${G}✅ 已重启${R}" || echo -e "${RED}重启失败${R}"; read -rs -n 1 -p "" ;;
            11) clear; sb_view_log ;; 12) clear; manual_open_port ;; 0|"") break ;; *) echo -e "${RED}无效${R}"; sleep 1 ;;
        esac
    done
}

# ================= 低配置服务器优化模块 =================
low_memory_optimize() {
    clear
    echo -e "${Y}========= 内存优化 =========${R}"
    echo ""
    
    echo -e "${Y}[1/5] 调整内存管理参数...${R}"
    echo 10 > /proc/sys/vm/swappiness
    echo 50 > /proc/sys/vm/vfs_cache_pressure
    echo 1 > /proc/sys/vm/dirty_ratio
    echo 1 > /proc/sys/vm/dirty_background_ratio
    echo 1000 > /proc/sys/vm/dirty_writeback_centisecs
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[2/5] 优化透明大页...${R}"
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[3/5] 关闭不必要的服务...${R}"
    for service in snapd ModemManager packagekit; do
        systemctl stop $service 2>/dev/null || true
        systemctl disable $service 2>/dev/null || true
    done
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[4/5] 优化日志记录...${R}"
    journalctl --vacuum-time=3d 2>/dev/null || true
    if [ -f /etc/systemd/journald.conf ]; then
        sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf 2>/dev/null || true
        sed -i 's/^#MaxLevelStore=.*/MaxLevelStore=err}' /etc/systemd/journald.conf 2>/dev/null || true
        systemctl restart systemd-journald 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[5/5] 检查并启用 ZRAM...${R}"
    auto_setup_zram
    echo -e "${G}✅ 完成${R}"
    
    cat > /etc/sysctl.d/99-lowmemory-optimize.conf <<EOF
# 低内存优化配置
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=1
vm.dirty_background_ratio=1
vm.dirty_writeback_centisecs=1000
EOF
    
    echo ""
    echo -e "${G}✅ 内存优化完成！${R}"
    read -rs -n 1 -p "按任意键继续..."
}

low_disk_optimize() {
    clear
    echo -e "${Y}========= 磁盘I/O优化 =========${R}"
    echo ""
    
    echo -e "${Y}[1/4] 优化挂载选项...${R}"
    if [ -f /etc/fstab ]; then
        if ! awk '$1 !~ /^#/ && $2 == "/" && $4 ~ /(^|,)noatime(,|$)/ { found=1 } END { exit found ? 0 : 1 }' /etc/fstab 2>/dev/null; then
            cp /etc/fstab /etc/fstab.bak.$(date +%s)
            awk '{ if ($1 !~ /^#/ && $2 == "/" && $4 !~ /(^|,)noatime(,|$)/) $4=$4",noatime"; print }' /etc/fstab > "$TMP_DIR/fstab.root.tmp" && mv "$TMP_DIR/fstab.root.tmp" /etc/fstab
        fi
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[2/4] 设置 I/O 调度器...${R}"
    local main_disk=$(lsblk -d -o NAME,ROTA | awk '$2==1{print $1}' | head -1)
    if [ -n "$main_disk" ]; then
        echo deadline > /sys/block/${main_disk}/queue/scheduler 2>/dev/null || true
        echo 128 > /sys/block/${main_disk}/queue/nr_requests 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[3/4] 减少磁盘日志...${R}"
    if [ -f /etc/syslog.conf ]; then
        sed -i 's/^\(.*\)\*\.\*/#\1\*.\*/' /etc/syslog.conf 2>/dev/null || true
    fi
    if [ -f /etc/systemd/journald.conf ]; then
        sed -i 's/^#RateLimitBurst=.*/RateLimitBurst=50}' /etc/systemd/journald.conf 2>/dev/null || true
        sed -i 's/^#RateLimitIntervalSec=.*/RateLimitIntervalSec=1m}' /etc/systemd/journald.conf 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[4/4] 优化 tmpfs 挂载...${R}"
    if [ -f /etc/fstab ] && grep -Eq '^[^#]+\s+/tmp\s+' /etc/fstab; then
        cp /etc/fstab /etc/fstab.bak.$(date +%s)
        awk '{ if ($1 !~ /^#/ && $2 == "/tmp" && $4 !~ /(^|,)size=128M(,|$)/) $4=$4",size=128M"; print }' /etc/fstab > "$TMP_DIR/fstab.tmp.tmp" && mv "$TMP_DIR/fstab.tmp.tmp" /etc/fstab
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo ""
    echo -e "${G}✅ 磁盘I/O优化完成！${R}"
    read -rs -n 1 -p "按任意键继续..."
}

low_sb_optimize() {
    clear
    echo -e "${Y}========= Sing-Box 资源限制优化 =========${R}"
    echo ""
    
    if ! command -v $SB_BIN >/dev/null 2>&1; then
        echo -e "${RED}❌ Sing-Box 未安装${R}"
        read -rs -n 1 -p "按任意键继续..."
        return
    fi
    
    echo -e "${Y}[1/3] 优化 systemd 资源限制...${R}"
    if [ -f /etc/systemd/system/sing-box.service ]; then
        local temp_service=$(mktemp)
        cp /etc/systemd/system/sing-box.service "$temp_service"
        if ! grep -q "MemoryMax" "$temp_service"; then
            sed -i '/\[Service\]/a LimitNOFILE=32768\nMemoryMax=512M\nMemoryHigh=256M\nCPUQuota=80%\nCPUWeight=200\nIOWeight=200' "$temp_service" 2>/dev/null || true
        fi
        if ! grep -q "Environment" "$temp_service"; then
            sed -i '/\[Service\]/a Environment=GODEBUG=madvdontneed=1' "$temp_service" 2>/dev/null || true
        fi
        cp "$temp_service" /etc/systemd/system/sing-box.service
        rm -f "$temp_service"
        systemctl daemon-reload
        systemctl restart sing-box >/dev/null 2>&1
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[2/3] 优化 Sing-Box 配置...${R}"
    if [ -f "$SB_CONF" ] && jq -e . "$SB_CONF" >/dev/null 2>&1; then
        jq '.log.level = "warn"' "$SB_CONF" > "$TMP_DIR/sb_opt.json" && mv "$TMP_DIR/sb_opt.json" "$SB_CONF"
        echo -e "${G}✅ 完成${R}"
    fi
    
    echo -e "${Y}[3/3] 禁用不必要的功能...${R}"
    if systemctl is-active --quiet sb-sub 2>/dev/null; then
        systemctl stop sb-sub >/dev/null 2>&1
        systemctl disable sb-sub >/dev/null 2>&1
        echo -e "${G}  已停止订阅服务以节省资源${R}"
    fi
    echo -e "${G}✅ 完成${R}"
    
    systemctl restart sing-box >/dev/null 2>&1
    echo ""
    echo -e "${G}✅ Sing-Box 资源限制优化完成！${R}"
    read -rs -n 1 -p "按任意键继续..."
}

low_profile_optimize() {
    clear
    echo -e "${G}╔══════════════════════════════════════════════╗"
    echo -e "║       低配置服务器一键优化                    ║"
    echo -e "╚══════════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${Y}此优化包含：${R}"
    echo -e "  ✅ 内存优化 (降低swappiness, 禁用THP)"
    echo -e "  ✅ 磁盘I/O优化 (noatime, 优化调度器)"
    echo -e "  ✅ 系统服务优化 (禁用非必要服务)"
    echo -e "  ✅ Sing-Box 资源限制 (如果已安装)"
    echo -e "  ✅ 内核网络参数 (适合低配置的网络优化)"
    echo ""
    
    if prompt_yes_no "确认执行一键优化？" "y"; then
        local mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        if [ "$mem_mb" -lt 512 ]; then
            echo -e "${Y}⚠ 检测到小于512MB内存，将应用最激进的优化${R}"
        fi
        
        echo -e "${Y}[1/6] 内存优化中...${R}"
        echo 1 > /proc/sys/vm/dirty_ratio
        echo 1 > /proc/sys/vm/dirty_background_ratio
        echo 30 > /proc/sys/vm/swappiness
        if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
            echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        fi
        
        echo -e "${Y}[2/6] 内核参数优化中...${R}"
        local opt_file="/etc/sysctl.d/99-lowprofile-optimize.conf"
        cat > "$opt_file" <<EOF
# 低配置服务器核心优化
vm.swappiness=30
vm.vfs_cache_pressure=100
vm.dirty_ratio=1
vm.dirty_background_ratio=1
vm.dirty_writeback_centisecs=200
net.core.rmem_max=1048576
net.core.wmem_max=1048576
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.somaxconn=1024
net.core.netdev_max_backlog=1000
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=512
net.ipv4.tcp_max_tw_buckets=1024
EOF
        sysctl -p "$opt_file" >/dev/null 2>&1
        
        echo -e "${Y}[3/6] 检查并配置Swap中...${R}"
        check_swap
        
        echo -e "${Y}[4/6] 优化挂载选项中...${R}"
        mount -o remount,noatime / 2>/dev/null || true
        
        echo -e "${Y}[5/6] 优化系统服务中...${R}"
        for service in snapd ModemManager packagekit; do
            systemctl stop $service 2>/dev/null || true
            systemctl disable $service 2>/dev/null || true
        done
        
        echo -e "${Y}[6/6] 检查Sing-Box中...${R}"
        if command -v $SB_BIN >/dev/null 2>&1; then
            if [ -f /etc/systemd/system/sing-box.service ]; then
                local temp_service=$(mktemp)
                cp /etc/systemd/system/sing-box.service "$temp_service"
                if ! grep -q "MemoryMax" "$temp_service"; then
                    sed -i '/\[Service\]/a LimitNOFILE=16384\nMemoryMax=256M\nMemoryHigh=128M\nCPUQuota=70%' "$temp_service" 2>/dev/null || true
                fi
                cp "$temp_service" /etc/systemd/system/sing-box.service
                rm -f "$temp_service"
                systemctl daemon-reload
                systemctl restart sing-box >/dev/null 2>&1
            fi
        fi
        
        echo ""
        echo -e "${G}✅ 低配置服务器优化完成！${R}"
        echo -e "${Y}建议重启服务器以完全应用优化${R}"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ================= TikTok 直播专门优化 =================
tiktok_live_optimize() {
    clear
    echo -e "${G}╔═══════════════════════════════════════════╗"
    echo -e "║       TikTok 直播专门优化                  ║"
    echo -e "╚═══════════════════════════════════════════╝${R}"
    echo ""
    echo -e "${Y}针对TikTok直播的优化内容：${R}"
    echo -e "  ✅ 低延迟网络配置 (适合实时直播)"
    echo -e "  ✅ UDP 流媒体优化 (减少直播卡顿)"
    echo -e "  ✅ 连接稳定性优化 (防止断流)"
    echo -e "  ✅ 带宽优化 (提高视频质量)"
    echo -e "  ✅ 网络队列优化 (减少延迟波动)"
    echo ""
    
    if prompt_yes_no "确认执行TikTok直播一键优化？" "y"; then
        echo -e "${Y}[1/7] 优化低延迟网络参数...${R}"
        local opt_file="/etc/sysctl.d/99-tiktok-live.conf"
        cat > "$opt_file" <<EOF
# TikTok 直播网络优化 - 低延迟优先
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=131072
net.core.wmem_default=131072
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.udp_rmem_min=131072
net.ipv4.udp_wmem_min=131072
net.core.netdev_max_backlog=50000
net.core.somaxconn=65535
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_fin_timeout=3
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_mtu_probing=1
net.ipv4.ip_local_port_range=1024 65535
net.netfilter.nf_conntrack_max=131072
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
EOF
        sysctl -p "$opt_file" >/dev/null 2>&1
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[2/7] 优化网络队列...${R}"
        local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
        if [ -n "$main_nic" ]; then
            tc qdisc replace dev "$main_nic" root fq 2>/dev/null || true
            echo 10000 > /sys/class/net/${main_nic}/tx_queue_len 2>/dev/null || true
            ethtool -K $main_nic gro on lro on tso on gso on 2>/dev/null || true
        fi
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[3/7] 优化UDP流媒体...${R}"
        if modprobe nf_conntrack 2>/dev/null; then
            echo 1048576 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
        fi
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[4/7] 调整内核实时性参数...${R}"
        echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true
        echo 500 > /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || true
        echo 15 > /proc/sys/vm/dirty_ratio 2>/dev/null || true
        echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null || true
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[5/7] 优化网络服务...${R}"
        for service in systemd-journald rsyslog; do
            systemctl restart $service >/dev/null 2>&1 || true
        done
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[6/7] 优化Sing-Box配置...${R}"
        if command -v $SB_BIN >/dev/null 2>&1; then
            if [ -f "$SB_CONF" ] && jq -e . "$SB_CONF" >/dev/null 2>&1; then
                jq '.log.level = "warn"' "$SB_CONF" > "$TMP_DIR/sb_tiktok.json" && mv "$TMP_DIR/sb_tiktok.json" "$SB_CONF"
                if [ -f /etc/systemd/system/sing-box.service ]; then
                    local temp_service=$(mktemp)
                    cp /etc/systemd/system/sing-box.service "$temp_service"
                    if ! grep -q "Nice=" "$temp_service"; then
                        sed -i '/\[Service\]/a LimitNOFILE=131072\nLimitNPROC=infinity\nNice=-10\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99' "$temp_service" 2>/dev/null || true
                    fi
                    cp "$temp_service" /etc/systemd/system/sing-box.service
                    rm -f "$temp_service"
                    systemctl daemon-reload
                fi
                systemctl restart sing-box >/dev/null 2>&1
            fi
        fi
        echo -e "${G}✅ 完成${R}"
        
        echo -e "${Y}[7/7] 优化防火墙和连接...${R}"
        for proto in tcp udp; do
            if command -v iptables >/dev/null 2>&1; then
                if ! iptables -t mangle -C OUTPUT -p $proto -j TOS --set-tos Minimize-Delay 2>/dev/null; then
                    iptables -t mangle -A OUTPUT -p $proto -j TOS --set-tos Minimize-Delay 2>/dev/null || true
                fi
            fi
        done
        echo -e "${G}✅ 完成${R}"
        
        check_swap >/dev/null 2>&1
        
        echo ""
        echo -e "${G}✅ TikTok 直播优化完成！${R}"
        echo -e "${Y}建议重启服务器以完全应用所有优化${R}"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

tiktok_udp_optimize() {
    clear
    echo -e "${Y}====== UDP 流媒体优化 ======${R}"
    echo ""
    echo -e "此优化针对TikTok直播的UDP传输，减少视频卡顿"
    echo ""
    
    echo -e "${Y}清理旧配置文件...${R}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-bandwidth.conf 2>/dev/null || true
    
    echo -e "${Y}[1/4] 增大UDP缓冲区...${R}"
    echo 131072 > /proc/sys/net/core/rmem_default 2>/dev/null || true
    echo 131072 > /proc/sys/net/core/wmem_default 2>/dev/null || true
    echo 33554432 > /proc/sys/net/core/rmem_max 2>/dev/null || true
    echo 33554432 > /proc/sys/net/core/wmem_max 2>/dev/null || true
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[2/4] 优化UDP连接跟踪...${R}"
    if modprobe nf_conntrack 2>/dev/null; then
        echo 120 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream 2>/dev/null || true
        echo 30 > /proc/sys/net/netfilter/nf_conntrack_udp_timeout 2>/dev/null || true
        echo 131072 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[3/4] 优化网络队列...${R}"
    local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$main_nic" ]; then
        tc qdisc replace dev "$main_nic" root fq 2>/dev/null || true
        echo 10000 > /sys/class/net/${main_nic}/tx_queue_len 2>/dev/null || true
        ethtool -K $main_nic gro on lro on tso on gso on 2>/dev/null || true
    fi
    echo -e "${G}✅ 完成${R}"
    
    echo -e "${Y}[4/4] 设置BBR+fq...${R}"
    echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    
    cat > /etc/sysctl.d/99-tiktok-udp.conf <<EOF
# TikTok 直播 UDP 优化
net.core.rmem_default=131072
net.core.wmem_default=131072
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.netfilter.nf_conntrack_udp_timeout_stream=120
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_max=131072
EOF
    echo -e "${G}✅ 完成${R}"
    
    echo ""
    echo -e "${G}✅ UDP 流媒体优化完成！${R}"
    read -rs -n 1 -p "按任意键继续..."
}

tiktok_bandwidth_optimize() {
    clear
    echo -e "${Y}╔═══════════════════════════════════╗${R}"
    echo -e "${Y}║      上下行带宽智能优化            ║${R}"
    echo -e "${Y}╚═══════════════════════════════════╝${R}"
    echo ""
    
    echo -e "${Y}清理旧配置文件...${R}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-tiktok-udp.conf 2>/dev/null || true
    
    echo -e "${Y}请选择您的带宽场景：${R}"
    echo ""
    echo -e "    ${H}[1] 家用宽带 (100-500Mbps)${R}"
    echo -e "    ${H}[2] 小带宽专线 (5-20Mbps)${R}"
    echo -e "    ${H}[3] 千兆网络 (1Gbps+)${R}"
    echo -e "    ${H}[4] 低延迟优先 (适合游戏/直播)${R}"
    echo -e "    ${H}[5] 自动检测并优化${R}"
    echo ""
    echo -e "    ${H}[0] 返回${R}"
    echo ""
    read -e -p "  请选择: " bw_choice
    
    local rmem_max wmem_max tcp_rmem tcp_wmem netdev_budget qdisc
    
    case "$bw_choice" in
        1)
            echo -e "${Y}正在优化家用宽带场景...${R}"
            rmem_max=33554432
            wmem_max=33554432
            tcp_rmem="4096 87380 33554432"
            tcp_wmem="4096 65536 33554432"
            netdev_budget=600
            qdisc="fq_codel"
            ;;
        2)
            echo -e "${Y}正在优化小带宽场景...${R}"
            rmem_max=8388608
            wmem_max=8388608
            tcp_rmem="4096 16384 8388608"
            tcp_wmem="4096 16384 8388608"
            netdev_budget=200
            qdisc="fq_codel"
            ;;
        3)
            echo -e "${Y}正在优化千兆网络...${R}"
            rmem_max=134217728
            wmem_max=134217728
            tcp_rmem="4096 87380 134217728"
            tcp_wmem="4096 65536 134217728"
            netdev_budget=1200
            qdisc="fq"
            ;;
        4)
            echo -e "${Y}正在优化低延迟场景...${R}"
            rmem_max=16777216
            wmem_max=16777216
            tcp_rmem="4096 16384 16777216"
            tcp_wmem="4096 16384 16777216"
            netdev_budget=300
            qdisc="fq"
            ;;
        5)
            echo -e "${Y}正在自动检测网络...${R}"
            local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
            local nic_speed=100
            if [ -n "$main_nic" ] && command -v ethtool >/dev/null 2>&1; then
                local detected_speed=$(ethtool "$main_nic" 2>/dev/null | grep -i speed | awk '{print $2}' | sed 's/Mb\/s//')
                if [[ "$detected_speed" =~ ^[0-9]+$ ]]; then
                    nic_speed="$detected_speed"
                fi
            fi
            
            if [ "$nic_speed" -lt 100 ]; then
                rmem_max=8388608
                wmem_max=8388608
                tcp_rmem="4096 16384 8388608"
                tcp_wmem="4096 16384 8388608"
                netdev_budget=200
                qdisc="fq_codel"
            elif [ "$nic_speed" -lt 1000 ]; then
                rmem_max=33554432
                wmem_max=33554432
                tcp_rmem="4096 87380 33554432"
                tcp_wmem="4096 65536 33554432"
                netdev_budget=600
                qdisc="fq_codel"
            else
                rmem_max=134217728
                wmem_max=134217728
                tcp_rmem="4096 87380 134217728"
                tcp_wmem="4096 65536 134217728"
                netdev_budget=1200
                qdisc="fq"
            fi
            echo -e "  检测到网络速度: ${nic_speed}Mbps"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选择${R}"
            sleep 1
            return
            ;;
    esac
    
    echo -e "${Y}正在应用优化...${R}"
    
    echo "$qdisc" > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    echo "$rmem_max" > /proc/sys/net/core/rmem_max 2>/dev/null || true
    echo "$wmem_max" > /proc/sys/net/core/wmem_max 2>/dev/null || true
    echo "$((rmem_max/4))" > /proc/sys/net/core/rmem_default 2>/dev/null || true
    echo "$((wmem_max/4))" > /proc/sys/net/core/wmem_default 2>/dev/null || true
    echo "$netdev_budget" > /proc/sys/net/core/netdev_budget 2>/dev/null || true
    
    cat > /etc/sysctl.d/99-bandwidth.conf << EOF
# 带宽优化配置
net.core.default_qdisc = $qdisc
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.rmem_default = $((rmem_max/4))
net.core.wmem_default = $((wmem_max/4))
net.ipv4.tcp_rmem = $tcp_rmem
net.ipv4.tcp_wmem = $tcp_wmem
net.core.netdev_budget = $netdev_budget
EOF
    sysctl -p /etc/sysctl.d/99-bandwidth.conf >/dev/null 2>&1
    
    local main_nic=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$main_nic" ]; then
        ethtool -K $main_nic gro on lro on tso on gso on 2>/dev/null || true
    fi
    
    echo ""
    echo -e "${G}✅ 带宽优化完成！${R}"
    echo -e "${Y}已应用配置：${R}"
    echo -e "  - 队列调度: $qdisc"
    echo -e "  - 缓冲区大小: $((rmem_max/1024/1024))MB"
    echo -e "  - 网络预算: $netdev_budget"
    echo ""
    read -rs -n 1 -p "按任意键继续..."
}

tiktok_live_menu() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗"
        echo -e "║       TikTok 直播优化菜单                  ║"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}[1] TikTok 直播一键优化${R}"
        echo -e "    ${H}[2] 仅UDP流媒体优化${R}"
        echo -e "    ${H}[3] 网络低延迟配置${R}"
        echo -e "    ${H}[4] 连接稳定性优化${R}"
        echo -e "    ${H}[5] 上下行带宽智能优化${R}"
        echo ""
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        read -e -p "  请选择: " c
        case "$c" in
            1) clear; tiktok_live_optimize ;;
            2) clear; tiktok_udp_optimize ;;
            3) 
                clear
                echo -e "${Y}正在优化网络低延迟...${R}"
                echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null
                echo bbr > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
                echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
                echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null
                echo -e "${G}✅ 低延迟网络优化完成！${R}"
                read -rs -n 1 -p "按任意键继续..."
                ;;
            4)
                clear
                echo -e "${Y}正在优化连接稳定性...${R}"
                echo 300 > /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null
                echo 10 > /proc/sys/net/ipv4/tcp_keepalive_intvl 2>/dev/null
                echo 3 > /proc/sys/net/ipv4/tcp_keepalive_probes 2>/dev/null
                echo 3 > /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null
                echo -e "${G}✅ 连接稳定性优化完成！${R}"
                read -rs -n 1 -p "按任意键继续..."
                ;;
            5) clear; tiktok_bandwidth_optimize ;;
            0|"") break ;;
            *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

low_profile_menu() {
    while true; do
        clear
        local mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        echo -e "${G}╔════════════════════════════════════════╗"
        echo -e "║       低配置服务器优化                   ║"
        echo -e "╚════════════════════════════════════════╝${R}"
        echo ""
        echo -e "    检测到内存: ${Y}${mem_mb}MB${R}"
        if [ "$mem_mb" -lt 512 ]; then
            echo -e "    ${RED}⚠ 极低内存，建议使用一键优化${R}"
        elif [ "$mem_mb" -lt 1024 ]; then
            echo -e "    ${Y}⚠ 低内存，建议使用一键优化${R}"
        fi
        echo ""
        echo -e "    ${Y}[1] 一键低配置服务器优化${R}"
        echo -e "    ${H}[2] 仅内存优化${R}"
        echo -e "    ${H}[3] 仅磁盘I/O优化${R}"
        echo -e "    ${H}[4] Sing-Box 资源限制${R}"
        echo ""
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        read -e -p "  请选择: " c
        case "$c" in
            1) clear; low_profile_optimize ;;
            2) clear; low_memory_optimize ;;
            3) clear; low_disk_optimize ;;
            4) clear; low_sb_optimize ;;
            0|"") break ;;
            *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

prompt_yes_no() {
    local msg="$1"
    local default="${2:-n}"
    read -e -p "${msg} (${default:0:1}/${default/n/y}): " yn
    [ -z "$yn" ] && yn="$default"
    [[ "$yn" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ================= 优化中心菜单 =================
optimization_center_menu() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗"
        echo -e "║           🚀 优化中心                        ║"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}⚠️  提示: 选下面其中一个即可，重复优化会互相覆盖${R}"
        echo ""
        echo -e "    ${Y}🌟 推荐选择${R}"
        echo -e "    ${G}[1] 智能自动优化 (推荐，适合99%用户)${R}"
        echo -e "        自动检测系统 + 网络优化 + 内存优化 + TikTok优化"
        echo ""
        echo -e "    ${Y}🔧 高级优化选项${R}"
        echo -e "    ${H}[2] Linux内核网络优化${R}"
        echo -e "    ${H}[3] BBRv3 (XanMod内核)${R}"
        echo -e "    ${H}[4] TikTok直播优化${R}"
        echo -e "    ${H}[5] 低配置服务器优化${R}"
        echo -e "    ${H}[6] Swap管理${R}"
        echo ""
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        read -e -p "  请选择 (推荐选1): " c
        case "$c" in
            1) clear; smart_auto_optimize ;;
            2) clear; Kernel_optimize ;;
            3) clear; bbrv3 ;;
            4) clear; tiktok_live_menu ;;
            5) clear; low_profile_menu ;;
            6) clear; change_swap_size ;;
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
        echo -e "    ${Y}[1] 🚀 优化中心（推荐）${R}"
        echo -e "    ${H}   - 所有优化功能都在这里${R}"
        echo ""
        echo -e "    ${Y}[2] 📦 Sing-Box 管理面板${R}"
        echo ""
        echo -e "    ${Y}[3] 📊 系统信息查询${R}"
        echo ""
        echo -e "    ${H}[0] 退出${R}"
        echo ""
        read -e -p "  请选择 (推荐选1): " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; optimization_center_menu ;;
            2) clear; sb_menu ;;
            3) clear; show_sys_info ;;
            0|"") echo -e "${G}再见！${R}"; exit 0 ;; *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

main_menu
