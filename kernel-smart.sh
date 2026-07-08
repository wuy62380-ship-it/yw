#!/usr/bin/env bash
export LANG=en_US.UTF-8

# ================= 颜色与基础定义 =================
: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[36m}"
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"

readp() { read -p "$(echo -e "${Y}$1${R}")" $2; }

root_use() { 
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行此脚本${R}" && exit 1 
}

send_stats() { :; return 0; }

# ================= 系统环境检测与依赖安装 =================
check_env() {
    local need_pkgs=("curl" "jq" "openssl" "iptables" "wget" "tar" "coreutils" "util-linux" "lsof" "bc")
    local need_update=0
    
    for pkg in "${need_pkgs[@]}"; do
        command -v $pkg >/dev/null 2>&1 || need_update=1
    done

    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        if command -v apt >/dev/null 2>&1; then 
            apt-get update -y >/dev/null 2>&1
            apt-get install -y "${need_pkgs[@]}" >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then 
            yum install -y epel-release >/dev/null 2>&1
            yum install -y "${need_pkgs[@]}" >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then 
            dnf install -y "${need_pkgs[@]}" >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then 
            apk update >/dev/null 2>&1
            apk add --no-cache "${need_pkgs[@]}" >/dev/null 2>&1
        fi
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
}

# ================= 防火墙与端口管理 =================
open_port_both() {
    local port=$1 opened=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${port}/tcp >/dev/null 2>&1; ufw allow ${port}/udp >/dev/null 2>&1; opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${port}/tcp >/dev/null 2>&1; firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; opened=1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
        iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
        command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables.rules 2>/dev/null
        opened=1
    fi
    if [ "$opened" -eq 1 ]; then echo -e "${G}  ✅ 已尝试放行 TCP/UDP ${port}${R}"; else echo -e "${Y}  ⚠ 自动放行失败，请直接在云控制台放行 TCP/UDP ${port}${R}"; fi
}

del_port_both() {
    local port=$1
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow ${port}/tcp >/dev/null 2>&1; ufw delete allow ${port}/udp >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port=${port}/tcp >/dev/null 2>&1; firewall-cmd --permanent --remove-port=${port}/udp >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
        iptables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    fi
}

# ================= Swap 与 ZRAM 管理 =================
check_swap() {
    local swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -ge 512 ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then swapon /swapfile >/dev/null 2>&1; swap_total=$(free -m | awk '/Swap/{print $2}'); [ "$swap_total" -ge 512 ] && return 0; fi
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${Y}创建 512MB Swap...${R}"; dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null; chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo -e "${G}✅ Swap 完成。${R}"; fi
}

auto_setup_zram() {
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then apt-get install -y zram-tools >/dev/null 2>&1 || return 1; fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null; sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1; fi
}

change_swap_size() {
    local swap_file="/swapfile" current_swap=$(free -m | awk '/Swap/{print $2}')
    clear; echo -e "${Y}======== Swap 管理 ========\n当前: ${G}${current_swap} MB${R}\n1.1G 2.2G 3.4G 4.6G 5.自定义 6.移除 0.返回"
    readp "选择: " c; local s=""
    case $c in 1) s=1024;; 2) s=2048;; 3) s=4096;; 4) s=6144;; 5) readp "大小(MB): " s; [[ ! "$s" =~ ^[0-9]+$ ]] && return;; 6) swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '/swapfile/d' /etc/fstab; return;; 0|"") return;; esac
    [ -z "$s" ] && return
    swapoff "$swap_file" 2>/dev/null; dd if=/dev/zero of="$swap_file" bs=1M count=$s 2>/dev/null; chmod 600 "$swap_file"
    mkswap "$swap_file" >/dev/null 2>&1; swapon "$swap_file" >/dev/null 2>&1
    grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "${G}✅ 完成${R}"; read -rs -n 1 -p ""
}

# ================= 内核与网络深度优化 =================
bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then if ! grep -q "tcp_congestion_control = bbr" "$CONF" 2>/dev/null; then sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"; echo "net.ipv4.tcp_congestion_control = bbr" >> "$CONF"; fi; sysctl -p "$CONF" >/dev/null 2>&1; fi
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
    
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 2048 ]; then MIN_FREE_KB=65536; RMEM_MAX=33554432; WMEM_MAX=33554432; TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"; BACKLOG=50000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 65536\nnet.ipv4.udp_wmem_min = 65536\nnet.ipv4.udp_rmem_max = 8388608\nnet.ipv4.udp_wmem_max = 8388608\nnet.core.netdev_budget = 800\nnet.core.netdev_max_backlog = 50000\nnet.core.optmem_max = 20480'
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; BACKLOG=10000; [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ] && STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 10000\nnet.core.optmem_max = 20480'
    else 
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; VFS_PRESSURE=50; DIRTY_RATIO=20; DIRTY_BG_RATIO=5
        RMEM_MAX=8388608; WMEM_MAX=8388608; SOMAXCONN=4096; BACKLOG=2000; SYN_BACKLOG=2048
        TCP_RMEM="4096 32768 8388608"; TCP_WMEM="4096 32768 8388608"
        HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""
        STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 2000\nnet.core.optmem_max = 16384'
        [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; check_swap; auto_setup_zram; fi

    local KVER=$(uname -r | grep -oP '^\d+\.\d+'); CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then modprobe tcp_bbr 2>/dev/null; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && { CC="bbr"; QDISC="fq"; }; fi
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ] && [ "$MEM_MB_VAL" -ge 1024 ] && STREAM_GAME_EXTRA="${STREAM_GAME_EXTRA:-${STREAM_EXTRA}}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288; [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"
    cat > "$CONF" << EOF
# 模式: ${mode_name}|${scene}
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
    sysctl -p "$CONF" >/dev/null 2>&1
    echo -e "${G}应用完成${R}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then echo -e "\n# YW-optimize\n* soft nofile 1048576\n* hard nofile 1048576" >> /etc/security/limits.conf; fi
    ulimit -n 1048576 2>/dev/null; check_swap >/dev/null 2>&1; bbr_on
    echo -e "${G}${mode_name} 完成！内存: ${MEM_MB_VAL}MB | 算法: ${CC}${R}"; read -rs -n 1 -p ""
}

restore_defaults() {
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    systemctl is-enabled zramswap >/dev/null 2>&1 && { systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; }
    echo -e "${G}已还原所有设置${R}"; read -rs -n 1 -p ""
}

Kernel_optimize() {
    root_use
    local scenes=("stream_game" "high" "balanced" "web" "stream" "game" "gateway")
    local names=("直播+游戏" "高性能" "均衡" "网站" "纯直播" "纯游戏" "中转网关")
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════╗"
        echo -e "║       Linux 内核网络优化            ║"
        echo -e "╚═══════════════════════════════════╝${R}"
        echo ""
        local i=0
        while [ $i -lt 7 ]; do
            local num=$((i + 1)); local scene="${scenes[$i]}"; local name="${names[$i]}"
            echo -e "    ${H}[${num}] ${name}${R}"
            i=$((i + 1))
        done
        echo -e "    ${H}─────────────────────────────${R}"
        echo -e "    ${H}[8]  还原默认${R}"
        echo -e "    ${H}[0]  返回${R}"
        echo ""
        readp "  选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; _kernel_optimize_core "直播+游戏" "stream_game" ;;
            2) clear; _kernel_optimize_core "高性能" "high" ;;
            3) clear; _kernel_optimize_core "均衡" "balanced" ;;
            4) clear; _kernel_optimize_core "网站" "web" ;;
            5) clear; _kernel_optimize_core "直播" "stream" ;;
            6) clear; _kernel_optimize_core "游戏" "game" ;;
            7) clear; _kernel_optimize_core "网关" "gateway" ;;
            8) clear; restore_defaults ;;
            0|"") break ;;
        esac
    done
}

# ================= 系统信息查询 =================
show_sys_info() {
    while true; do
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
        echo -e "${C}系统版本:       ${R}${os_info}
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
        readp "请输入选择: " menu_choice
        case "$menu_choice" in 0|"") break ;; esac
    done
    return 0
}

# ================= BBRv3 (XanMod) =================
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc); elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then echo -e "${RED}XanMod 已停止支持当前系统版本${R}"; return 1; fi
    [ -z "$os_codename" ] && { echo -e "${RED}无法获取系统代号${R}"; return 1; }
    apt-get install -y wget gnupg ca-certificates >/dev/null 2>&1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    return 0
}

xanmod_detect_package() {
    local psabi_level=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit}}' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3
    for prefix in linux-xanmod linux-xanmod-lts; do 
        local l="$psabi_level"; 
        while [ "$l" -ge 1 ]; do 
            local p="${prefix}-x64v${l}"; 
            if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^ ]'; then 
                echo "$p"; return 0; 
            fi; 
            l=$((l-1)); 
        done; 
    done; 
    return 1
}

bbrv3() {
    root_use
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════╗"
        echo -e "║          BBRv3 (XanMod) 管理         ║"
        echo -e "╚═══════════════════════════════════╝${R}"
        
        local current_kernel=$(uname -r)
        local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        
        if echo "$current_kernel" | grep -q "xanmod"; then
            echo -e "当前内核: ${G}${current_kernel}${R}"
            echo -e "当前算法: ${G}${current_cc}${R}"
            echo -e "状态: ${G}已安装 XanMod 内核${R}"
        else
            echo -e "当前内核: ${Y}${current_kernel}${R}"
            echo -e "当前算法: ${Y}${current_cc}${R}"
            echo -e "状态: ${Y}未安装 XanMod 内核${R}"
        fi
        echo -e "----------------------------------------------"
        
        if [ "$(uname -m)" = "aarch64" ]; then 
            echo -e "${Y}ARM架构不支持 XanMod，请使用系统默认BBR${R}"
            read -rs -n 1 -p "按任意键返回..."
            return 0
        fi
        
        if [ -r /etc/os-release ]; then 
            . /etc/os-release
            if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then 
                echo -e "${RED}XanMod 内核仅支持 Debian/Ubuntu 系统${R}"
                read -rs -n 1 -p "按任意键返回..."
                return 0
            fi
        else 
            return 0
        fi

        if echo "$current_kernel" | grep -q "xanmod"; then
            echo -e "    ${H}[1] 更新 XanMod 内核${R}"
            echo -e "    ${H}[2] 卸载 XanMod 内核${R}"
        else
            echo -e "    ${H}[1] 安装 XanMod 内核并开启 BBRv3${R}"
        fi
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        readp "  请选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        
        case "$c" in
            1)
                echo -e "${Y}正在准备环境...${R}"
                check_swap >/dev/null 2>&1
                if ! xanmod_add_repo; then
                    read -rs -n 1 -p "添加 XanMod 源失败，按任意键返回..."
                    continue
                fi
                apt update -y >/dev/null 2>&1
                local pkg=$(xanmod_detect_package)
                if [ -z "$pkg" ]; then
                    echo -e "${RED}未检测到适合当前 CPU 的内核包${R}"
                    read -rs -n 1 -p "按任意键返回..."
                    continue
                fi
                
                echo -e "${Y}开始下载并安装/更新 ${pkg} ...${R}"
                if echo "$current_kernel" | grep -q "xanmod"; then
                    apt install -y --only-upgrade "$pkg"
                else
                    apt install -y "$pkg"
                fi
                
                bbr_on
                echo -e "${G}✅ 操作完成！${R}"
                readp "是否现在重启系统以应用新内核？: " rc
                [[ "$rc" =~ ^[Yy]$ ]] && reboot
                ;;
            2)
                readp "确认卸载 XanMod 内核并恢复系统默认？: " uc
                if [[ "$uc" =~ ^[Yy]$ ]]; then
                    apt purge -y 'linux-*xanmod*'
                    apt autoremove -y
                    update-grub 2>/dev/null
                    rm -f /etc/apt/sources.list.d/xanmod-release.list
                    echo -e "${G}✅ 卸载完成！${R}"
                    readp "必须重启系统才能生效，是否现在重启？: " rc
                    [[ "$rc" =~ ^[Yy]$ ]] && reboot
                fi
                ;;
            0|"") break ;;
        esac
    done
}

# ================= 直播承载能力评估 =================
estimate_stream_capacity() {
    clear
    echo -e "${Y}===== 直播承载能力评估 =====${R}"
    echo -e "1. 手动输入带宽"
    echo -e "2. 自动实测带宽 (约10秒)"
    readp "请选择: " speed_choice
    
    local up_bw=0 down_bw=0
    if [ "$speed_choice" = "2" ]; then
        echo -e "${Y}正在测试下行带宽...${R}"
        local down_speed_bps=$(curl -o /dev/null -s -w "%{speed_download}" --max-time 15 "https://speed.cloudflare.com/__down?bytes=10000000")
        down_bw=$(awk "BEGIN{printf \"%.0f\", ${down_speed_bps:-0} * 8 / 1000000}")
        echo -e "${Y}正在测试上行带宽...${R}"
        local up_speed_bps=$(head -c 10000000 /dev/zero 2>/dev/null | curl -o /dev/null -s -w "%{speed_upload}" --max-time 15 -X POST -H "Content-Type: application/octet-stream" --data-binary @- "https://speed.cloudflare.com/__up")
        up_bw=$(awk "BEGIN{printf \"%.0f\", ${up_speed_bps:-0} * 8 / 1000000}")
        if [ "$up_bw" -eq 0 ] || [ "$down_bw" -eq 0 ]; then echo -e "${RED}自动测速失败，请改用手动输入。${R}"; speed_choice="1"; fi
    fi
    if [ "$speed_choice" != "2" ]; then
        readp "服务器上行带宽: " up_bw
        readp "服务器下行带宽: " down_bw
    fi
    if [[ ! "$up_bw" =~ ^[0-9]+$ ]] || [[ ! "$down_bw" =~ ^[0-9]+$ ]] || [ "$up_bw" -eq 0 ] || [ "$down_bw" -eq 0 ]; then echo -e "${RED}输入或测速无效${R}"; read -rs -n 1 -p ""; return; fi

    local cpu_cores=$(nproc)
    local mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
    local effective_up=$((up_bw * 8 / 10))
    local effective_down=$((down_bw * 8 / 10))
    local bw_up_1080p=$((effective_up / 6))
    local bw_down_1080p=$((effective_down / 2))
    local bw_limit_1080=$bw_up_1080p; [ "$bw_down_1080p" -lt "$bw_limit_1080" ] && bw_limit_1080=$bw_down_1080p
    local bw_up_720p=$((effective_up / 3))
    local bw_down_720p=$((effective_down / 1))
    local bw_limit_720=$bw_up_720p; [ "$bw_down_720p" -lt "$bw_limit_720" ] && bw_limit_720=$bw_down_720p
    local cpu_limit=$((cpu_cores * 2))
    local mem_limit=$(( (mem_mb - 512) / 100 )); [ "$mem_limit" -lt 0 ] && mem_limit=0
    local rec_1080=$bw_limit_1080; [ "$cpu_limit" -lt "$rec_1080" ] && rec_1080=$cpu_limit; [ "$mem_limit" -lt "$rec_1080" ] && rec_1080=$mem_limit
    local rec_720=$bw_limit_720; [ "$cpu_limit" -lt "$rec_720" ] && rec_720=$cpu_limit; [ "$mem_limit" -lt "$rec_720" ] && rec_720=$mem_limit

    echo -e "\n${G}===== 评估结果 =====${R}"
    echo -e "硬件配置: ${Y}${cpu_cores}核 CPU / ${mem_mb}MB 内存${R}"
    echo -e "网络带宽: ${Y}上行 ${up_bw}Mbps / 下行 ${down_bw}Mbps${R}"
    echo -e "------------------------"
    echo -e "${C}理论上限 (仅考虑带宽):${R}"
    echo -e "  - 1080P直播: 约 ${G}${bw_limit_1080}${R} 路"
    echo -e "  - 720P直播 : 约 ${G}${bw_limit_720}${R} 路"
    echo -e "${C}硬件瓶颈 (CPU/内存):${R}"
    echo -e "  - CPU瓶颈 : 约 ${G}${cpu_limit}${R} 路"
    echo -e "  - 内存瓶颈: 约 ${G}${mem_limit}${R} 路"
    echo -e "------------------------"
    echo -e "${Y}🌟 综合推荐带货量 (取最短板):${R}"
    echo -e "  - 推荐 1080P 主播数: ${G}${rec_1080}${R} 个"
    echo -e "  - 推荐 720P 主播数 : ${G}${rec_720}${R} 个"
    echo -e "${H}注: 评估已预留20%带宽用于游戏/网页, 并考虑了加解密损耗。${R}"
    read -rs -n 1 -p ""
}

# ================= Sing-Box 管理 (强容错版) =================
SB_CONF="/etc/sing-box/config.json"
META_FILE="/etc/sing-box/.nodes_meta"

sb_check() { 
    if ! command -v /etc/sing-box/sing-box >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return 1; fi
    return 0
}

sb_init_conf() { 
    if [ ! -f "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1; then 
        mkdir -p /etc/sing-box
        # 彻底修复出站路由配置，确保流量能正确出去，并适配 1.11.0+ 的 sniff 规范
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"action":"sniff"}],"final":"direct","auto_detect_interface":true}}' > "$SB_CONF"
    fi
    [ ! -f "$META_FILE" ] && echo '{}' > "$META_FILE" && chmod 600 "$META_FILE"
}

_save_node_meta() {
    sb_init_conf; local tmp="/tmp/sb_meta.json.$$"
    if [ -n "$4" ]; then jq --arg p "$1" --arg n "$2" --arg t "$3" --arg pk "$4" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "pub_key": $pk, "extra": $ex}' "$META_FILE" > "$tmp"
    else jq --arg p "$1" --arg n "$2" --arg t "$3" --arg ex "$5" '.[$p] = {"name": $n, "type": $t, "extra": $ex}' "$META_FILE" > "$tmp"
    fi
    [ -s "$tmp" ] && { mv -f "$tmp" "$META_FILE"; chmod 600 "$META_FILE"; } || rm -f "$tmp"
}

_del_node_meta() { [ -f "$META_FILE" ] && jq --arg p "$1" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; }
_get_node_meta() { [ -f "$META_FILE" ] && jq -r --arg p "$1" --arg f "$2" '.[$p][$f] // empty' "$META_FILE"; }

get_my_ip() { curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -6 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || echo "未知IP"; }
url_encode() { printf '%s' "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/@/%40/g'; }

sb_install() {
    if command -v /etc/sing-box/sing-box >/dev/null 2>&1; then echo -e "${Y}Sing-Box 已安装！${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m)
    case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) echo -e "${RED}❌ 不支持 ${arch}${R}"; read -rs -n 1 -p ""; return 1;; esac
    
    echo -e "${Y}即将安装 Sing-Box (${arch})${R}"; readp "继续？: " c; [[ ! "$c" =~ ^[Yy]$ ]] && return
    echo -e "${Y}正在下载最新版...${R}"
    local latest_ver=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
    [ -z "$latest_ver" ] && latest_ver="1.10.7"
    
    mkdir -p /etc/sing-box
    if curl -L -o /tmp/sb.tar.gz -# --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"; then
        tar xzf /tmp/sb.tar.gz -C /tmp
        mv /tmp/sing-box-${latest_ver}-linux-${arch}/sing-box /etc/sing-box/sing-box
        rm -rf /tmp/sb.tar.gz /tmp/sing-box-${latest_ver}-linux-${arch}
        chmod +x /etc/sing-box/sing-box
        
        sb_init_conf
        if command -v systemctl >/dev/null 2>&1; then
            cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -c $SB_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable sing-box >/dev/null 2>&1; systemctl start sing-box
        elif command -v rc-service >/dev/null 2>&1; then
            cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -c $SB_CONF"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF
            chmod +x /etc/init.d/sing-box; rc-update add sing-box default; rc-service sing-box start
        fi
        echo -e "${G}✅ 安装成功 | 版本: $(/etc/sing-box/sing-box version 2>/dev/null | head -1)${R}"
    else
        echo -e "${RED}❌ 下载失败，请检查网络是否能访问 Github${R}"
    fi
    read -rs -n 1 -p ""
}

sb_add_reality() {
    sb_check || return
    readp "端口 (回车随机): " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1)
    while ss -tunlp | grep -w ":$port" >/dev/null 2>&1; do readp "端口 $port 被占用，请重新输入: " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1); done
    local sni="www.microsoft.com"
    local uuid=$(/etc/sing-box/sing-box generate uuid 2>/dev/null)
    local keys=$(/etc/sing-box/sing-box generate reality-keypair 2>/dev/null)
    local priv_key=$(echo "$keys" | awk '/PrivateKey/{print $2}' | tr -d '"')
    local pub_key=$(echo "$keys" | awk '/PublicKey/{print $2}' | tr -d '"')
    local short_id=$(/etc/sing-box/sing-box generate rand --hex 4 2>/dev/null || echo "aabbccdd")
    
    if [ -z "$uuid" ] || [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        echo -e "${RED}❌ 生成核心参数失败，sing-box 可能无法正常运行，请尝试卸载后重新安装！${R}"
        /etc/sing-box/sing-box version
        read -rs -n 1 -p ""
        return 1
    fi

    readp "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-Reality-${port}"

    sb_init_conf; cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" '{"type":"vless","tag":("vless-reality-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    
    if /etc/sing-box/sing-box check -c "$SB_CONF" 2>/tmp/sb_err.log; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-reality" "$pub_key" "short_id=${short_id}"
        systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null; sleep 2
        echo -e "${G}✅ 成功 | PublicKey: ${pub_key} | short_id: ${short_id}${R}"
        local link_ip=$(get_my_ip)
        # 链接增加 headerType=none 确保兼容所有客户端
        [ "$link_ip" != "未知IP" ] && echo -e "${C}vless://${uuid}@${link_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#$(url_encode "$nn")${R}"
    else
        echo -e "${RED}校验失败，回滚配置。错误信息如下：${R}"
        cat /tmp/sb_err.log
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
    fi
    read -rs -n 1 -p ""
}

sb_add_vless_ws() {
    sb_check || return
    readp "端口 (回车随机): " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1)
    while ss -tunlp | grep -w ":$port" >/dev/null 2>&1; do readp "端口 $port 被占用，请重新输入: " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1); done
    local ws_path="/$(openssl rand -hex 8)"; readp "WS Path (回车默认): " wp; [ -n "$wp" ] && ws_path="$wp"
    readp "名称 (回车默认): " nn; [ -z "$nn" ] && nn="VLESS-WS-${port}"
    local uuid=$(/etc/sing-box/sing-box generate uuid 2>/dev/null)

    if [ -z "$uuid" ]; then
        echo -e "${RED}❌ 生成 UUID 失败，sing-box 可能无法正常运行，请尝试卸载后重新安装！${R}"
        /etc/sing-box/sing-box version
        read -rs -n 1 -p ""
        return 1
    fi

    sb_init_conf; cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg wp "$ws_path" '{"type":"vless","tag":("vless-ws-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"uuid":$u}],"transport":{"type":"ws","path":$wp,"max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    
    if /etc/sing-box/sing-box check -c "$SB_CONF" 2>/tmp/sb_err.log; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "vless-ws" "" "path=${ws_path}"
        systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null; sleep 2
        echo -e "${G}✅ 成功 | Path: ${ws_path}${R}"
        local link_ip=$(get_my_ip)
        [ "$link_ip" != "未知IP" ] && echo -e "${C}vless://${uuid}@${link_ip}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path}")#$(url_encode "$nn")${R}"
    else
        echo -e "${RED}校验失败，回滚配置。错误信息如下：${R}"
        cat /tmp/sb_err.log
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
    fi
    read -rs -n 1 -p ""
}

sb_add_hysteria2() {
    sb_check || return
    readp "端口 (回车随机): " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1)
    while ss -tunlp | grep -w ":$port" >/dev/null 2>&1; do readp "端口 $port 被占用，请重新输入: " port; [[ -z "$port" ]] && port=$(shuf -i 10000-65535 -n 1); done
    local pwd=$(openssl rand -base64 24 | tr -d '\n/=+' | head -c 32)
    local hy2_sni="www.bing.com"
    readp "名称 (回车默认): " nn; [ -z "$nn" ] && nn="Hysteria2-${port}"
    
    local cert_dir="/etc/sing-box/certs/hy2-${port}"; mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=${hy2_sni}" 2>/dev/null
    
    sb_init_conf; cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    local ij=$(jq -n --argjson p "$port" --arg pwd "$pwd" --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" --arg s "${hy2_sni}" '{"type":"hysteria2","tag":("hysteria2-"+($p|tostring)),"listen":"::","listen_port":$p,"users":[{"password":$pwd}],"ignore_client_bandwidth":false,"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$c,"key_path":$k}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    
    if /etc/sing-box/sing-box check -c "$SB_CONF" 2>/tmp/sb_err.log; then
        open_port_both "$port"; _save_node_meta "$port" "$nn" "hysteria2" "" "password=${pwd};tls_method=selfsign;sni=${hy2_sni}"
        systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null; sleep 2
        echo -e "${G}✅ 成功 | 密码: ${pwd} | SNI: ${hy2_sni}${R}"
        local link_ip=$(get_my_ip)
        # 彻底修复客户端兼容性：同时带 insecure 和 allowInsecure
        [ "$link_ip" != "未知IP" ] && echo -e "${C}hysteria2://$(url_encode "$pwd")@${link_ip}:${port}?insecure=1&allowInsecure=1&sni=${hy2_sni}&alpn=h3#$(url_encode "$nn")${R}"
    else
        echo -e "${RED}校验失败，回滚配置。错误信息如下：${R}"
        cat /tmp/sb_err.log
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
    fi
    read -rs -n 1 -p ""
}

sb_show_nodes_and_links() {
    sb_check || return
    [ ! -f "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1 && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    local server_ip=$(get_my_ip)
    echo -e "\n${Y}===== 节点列表与链接 =====${R}\n${H}服务器地址: ${server_ip}${R}\n"
    local idx=1 has_any=0
    while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null); [ -z "$obj" ] && continue
        local port inb_type nn display link=""
        port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null); [ -z "$port" ] && continue
        local meta_name=$(_get_node_meta "$port" "name"); [ -z "$meta_name" ] && continue
        inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null); nn="$meta_name"
        case "$inb_type" in vless) display="VLESS" ;; hysteria2) display="Hysteria2" ;; *) display="$inb_type" ;; esac
        echo -e "${G}━━━ [${idx}] ${display} | 端口: ${port} | ${nn} ━━━${R}"; has_any=1
        case "$inb_type" in
            vless) local uuid flow tls_enabled sni pub_key short_id ws_path
                uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                [ -n "$uuid" ] && {
                    flow=$(echo "$obj" | jq -r '.users[0].flow // empty' 2>/dev/null); tls_enabled=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)
                    if [ "$tls_enabled" = "true" ] && echo "$obj" | jq -e '.tls.reality' >/dev/null 2>&1; then
                        sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null); pub_key=$(_get_node_meta "$port" "pub_key")
                        short_id=$(echo "$obj" | jq -r '.tls.reality.short_id[0] // empty' 2>/dev/null); local flow_param=""; [ -n "$flow" ] && flow_param="&flow=${flow}"
                        link="vless://${uuid}@${server_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#$(url_encode "$nn")"
                    else ws_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null); link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=none&type=ws&path=$(url_encode "${ws_path:-/}")#$(url_encode "$nn")"; fi
                } ;;
            hysteria2) local pwd sni; 
                pwd=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                sni="www.bing.com"
                [ -n "$pwd" ] && link="hysteria2://$(url_encode "$pwd")@${server_ip}:${port}?insecure=1&allowInsecure=1&sni=${sni}&alpn=h3#$(url_encode "$nn")"; ;;
        esac
        [ -n "$link" ] && echo -e "${C}${link}${R}"; echo ""; idx=$((idx + 1))
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
    readp "请输入要删除的端口号 (0返回): " del_input
    [ -z "$del_input" ] || [[ "$del_input" == "0" ]] && return
    if ! [[ "$del_input" =~ ^[0-9]+$ ]]; then echo -e "${RED}无效输入${R}"; read -rs -n 1 -p ""; return; fi
    
    local found_tag=$(jq -r --argjson p "$del_input" '.inbounds[] | select(.listen_port == $p) | .tag' "$SB_CONF" 2>/dev/null | head -1)
    if [ -z "$found_tag" ]; then echo -e "${RED}未找到端口 ${del_input} 对应的节点${R}"; read -rs -n 1 -p ""; return; fi
    
    del_port_both "$del_input"
    cp "$SB_CONF" "${SB_CONF}.bak.$(date +%s)"
    jq --arg t "$found_tag" 'del(.inbounds[] | select(.tag == $t))' "$SB_CONF" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$SB_CONF"
    if /etc/sing-box/sing-box check -c "$SB_CONF" 2>/tmp/sb_err.log; then
        _del_node_meta "$del_input"; systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null; sleep 1
        echo -e "${G}✅ 已删除端口 ${del_input} 的节点${R}"
    else 
        echo -e "${RED}删除后校验失败，回滚...错误信息如下：${R}"
        cat /tmp/sb_err.log
        local latest_bak=$(ls -t "${SB_CONF}.bak."* 2>/dev/null | head -1); [ -n "$latest_bak" ] && mv "$latest_bak" "$SB_CONF"
    fi
    read -rs -n 1 -p ""
}

sb_menu() {
    while true; do
        clear
        local sb_status_text="${H}未安装${R}"
        if command -v /etc/sing-box/sing-box >/dev/null 2>&1; then
            if systemctl is-active --quiet sing-box 2>/dev/null || rc-service sing-box status 2>/dev/null | grep -q "started"; then sb_status_text="${G}● 运行中${R}"
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
        echo -e "    ${H}[4] 查看节点与链接${R}"
        echo -e "    ${H}[5] 删除节点(输端口)${R}"
        echo -e "    ${H}────────────────────────${R}"
        echo -e "    ${H}[6] 安装 Sing-Box${R}"
        echo -e "    ${H}[7] 卸载 Sing-Box${R}"
        echo -e "    ${H}[8] 重启 Sing-Box${R}"
        echo ""
        echo -e "    ${H}[0] 返回主菜单${R}"
        echo ""
        readp "  选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) clear; sb_add_reality ;;
            2) clear; sb_add_vless_ws ;;
            3) clear; sb_add_hysteria2 ;;
            4) clear; sb_show_nodes_and_links ;;
            5) clear; sb_del_node ;;
            6) clear; sb_install ;;
            7) clear; readp "确认卸载？: " uc; [[ "$uc" =~ ^[Yy]$ ]] && { systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null; rc-service sing-box stop 2>/dev/null; rc-update del sing-box 2>/dev/null; rm -rf /etc/sing-box /etc/systemd/system/sing-box.service /etc/init.d/sing-box; echo -e "${G}✅ 已卸载${R}"; } ;;
            8) clear; systemctl restart sing-box 2>/dev/null || rc-service sing-box restart 2>/dev/null; echo -e "${G}✅ 已重启${R}" ;;
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
        local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local bbr_status="${H}[当前: ${current_cc:-未知}]${R}"
        if echo "$(uname -r)" | grep -q "xanmod"; then
            bbr_status="${G}[已装 XanMod: ${current_cc:-未知}]${R}"
        fi

        echo -e "${G}╔══════════════════════════════════════╗"
        echo -e "║          YW 服务器优化工具箱            ║"
        echo -e "╚══════════════════════════════════════╝${R}"
        echo ""
        echo -e "    ${Y}[1] 系统信息查询${R}"
        echo -e "    ${Y}[2] BBRv3 (XanMod内核) ${bbr_status}"
        echo -e "    ${Y}[3] Sing-Box 管理面板${R}"
        echo -e "    ${Y}[4] Linux 内核网络优化${R}"
        echo -e "    ${Y}[5] Swap 管理${R}"
        echo -e "    ${Y}[6] 直播承载能力评估${R}"
        echo ""
        echo -e "    ${H}[0] 退出${R}"
        echo ""
        readp "  请选择: " c
        c=$(echo "$c" | tr -d '[:space:]')
        case "$c" in
            1) show_sys_info ;;
            2) bbrv3 ;;
            3) sb_menu ;;
            4) Kernel_optimize ;;
            5) change_swap_size ;;
            6) clear; estimate_stream_capacity ;;
            0|"") echo -e "${G}再见！${R}"; exit 0 ;;
            *) echo -e "${RED}无效选择${R}"; sleep 1 ;;
        esac
    done
}

main_menu
