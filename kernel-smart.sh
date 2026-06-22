#!/usr/bin/env bash
# ============================================================================
# YW 内核与网络调优模块
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_hong:=\033[31m}"
: "${gl_kjlan:=\033[32m}"

# --- 全局变量 ---
: "${gh_proxy:=https://}"
: "${tiaoyou_moshi:=默认优化模式}"

# ============================================================================
# Helper Functions
# ============================================================================

send_stats() { :; return 0; }

root_use() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${gl_red}错误：请使用 root 用户运行此脚本${gl_bai}"
        exit 1
    fi
}

check_swap() {
    local swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -lt 512 ] && [ -f /swapfile ]; then
        echo -e "${gl_huang}Swap file detected, skipping creation.${gl_bai}"
        return 0
    elif [ "$swap_total" -lt 512 ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        echo -e "${gl_lv}Swap created and activated (512MB).${gl_bai}"
    fi
}

check_disk_space() {
    local required_mb=$1
    local available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo -e "${gl_red}错误: 磁盘空间不足，需要 ${required_mb}MB，当前可用: ${available_mb}MB${gl_bai}"
        return 1
    fi
    return 0
}

install() {
    if command -v apt >/dev/null 2>&1; then
        if ! apt-get install -y "$@" >/tmp/yw_apt.log 2>&1; then echo -e "${gl_red}APT 失败:${gl_bai}"; tail -n 3 /tmp/yw_apt.log; return 1; fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y "$@" >/tmp/yw_yum.log 2>&1; then echo -e "${gl_red}YUM 失败:${gl_bai}"; tail -n 3 /tmp/yw_yum.log; return 1; fi
    fi
    return 0
}

server_reboot() {
    echo -e "${gl_lv}建议立即重启服务器以加载新内核...${gl_bai}"
    read -e -p "是否现在重启？: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then reboot; fi
}

bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then
        if ! grep -q "tcp_congestion_control = bbr" "$CONF" 2>/dev/null; then
            sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"
            echo "net.ipv4.tcp_congestion_control = bbr" >> "$CONF"
        fi
        sysctl -p "$CONF" >/dev/null 2>&1
    fi
    return 0
}

break_end() {
    local choice="$1"
    [ -z "$choice" ] || [ "$choice" = "0" ] || [ "$choice" = "return" ]
}

# ============================================================================
# Swap Management Module
# ============================================================================

change_swap_size() {
    local swap_file="/swapfile"
    local current_swap=$(free -m | awk '/Swap/{print $2}')
    clear
    echo -e "${gl_huang}========================================\n        Swap 虚拟内存管理\n========================================${gl_bai}"
    echo -e "当前 Swap 大小: ${gl_lv}${current_swap} MB${gl_bai} | 磁盘剩余: $(df -m / | tail -1 | awk '{print $4}') MB\n"
    echo -e "1. 1GB  2. 2GB  3. 4GB  4. 6GB  5. 自定义(MB)  6. 移除  0. 返回"
    read -e -p "请输入选择: " swap_choice
    local swap_size=""
    case "$swap_choice" in
        1) swap_size=1024 ;; 2) swap_size=2048 ;; 3) swap_size=4096 ;; 4) swap_size=6144 ;;
        5) read -e -p "大小(最小512): " swap_size; [[ -z "$swap_size" || "$swap_size" -lt 512 ]] && echo -e "${gl_red}错误${gl_bai}" && return 0 ;;
        6) if [ "$current_swap" -gt 0 ]; then swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '/swapfile.*swap/d' /etc/fstab; echo -e "${gl_lv}已移除${gl_bai}"; fi; return 0 ;;
        *) return 0 ;;
    esac
    if [ -n "$swap_size" ]; then
        local avail=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$avail" -lt $((swap_size + 100)) ]; then echo -e "${gl_red}空间不足${gl_bai}"; return 0; fi
        echo -e "${gl_lv}正在创建 ${swap_size}MB...${gl_bai}"; swapoff "$swap_file" 2>/dev/null
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null; chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1; swapon "${swap_file}" >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ 成功${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# Core Optimization Logic (全场景极限特化)
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-high}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}正在应用${mode_name}参数..."

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE
    local SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN=16384
    local TCP_NOTSENT_LOWAT=16384 TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1
    local GAME_EXTRA="" STREAM_EXTRA="" HIGH_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA=""
    local TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0 

    case "$scene" in
        high)
            SWAPPINESS=10; OVERCOMMIT=1; VFS_PRESSURE=50
            DIRTY_RATIO=40; DIRTY_BG_RATIO=10 # 【特化】大幅拉高脏页比例，允许内存攒够40%再一次性写盘，极其提升大文件IO吞吐
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            HIGH_EXTRA="
# ── 高性能模式 IO 聚簇写回特化 ──
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10"
            ;;
        web)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3 
            WEB_EXTRA="
# ── 网站模式极限抗并发特化 ──
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_max_syn_backlog = 16384"
            ;;
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=131072
            STREAM_EXTRA="
# ── 直播模式 UDP 极限特化 ──
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.udp_rmem_max = 16777216
net.ipv4.udp_wmem_max = 16777216
net.core.netdev_budget = 1200
net.core.netdev_max_backlog = 500000"
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072
            # 【极限特化】真正电竞级防卡顿，TCP Buffer 必须砍到 8MB 绝杀 Bufferbloat
            RMEM_MAX=8388608; WMEM_MAX=8388608 
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=5
            KEEPALIVE_TIME=60; KEEPALIVE_INTVL=10; KEEPALIVE_PROBES=3
            UDP_RMEM_MIN=131072
            GAME_EXTRA="
# ── 游戏模式微秒级低延迟特化 ──
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.core.optmem_max = 20480"
            ;;
        balanced)
            SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
            MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"
            SCHED_AUTOGROUP=0; THP="always"; NUMA=1; FIN_TIMEOUT=30
            KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
            TCP_SLOW_START_AFTER_IDLE=1
            BALANCED_EXTRA="
# ── 均衡模式内存安全锁 ──
vm.overcommit_memory = 0"
            ;;
        *) echo -e "${gl_red}错误: 未知场景${gl_bai}"; return 1 ;;
    esac

    # ========================================================================
    # 智能硬件检测与“调虎离山”Swap 策略
    # ========================================================================
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP=$(free -m | awk '/Swap/{print $2}')

    if [ "$MEM_MB_VAL" -ge 16384 ]; then
        MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 4096 ]; then
        MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then
        MIN_FREE_KB=32768
        if [ "$scene" != "balanced" ] && [ "$scene" != "game" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
        fi
        # 1-4GB 内存的游戏模式，8MB 太勉强，回退 16MB 保底
        if [ "$scene" = "game" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
            GAME_EXTRA="
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072"
        fi
    else
        # 【< 1GB 极限保命】清空所有野兽参数
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10
        RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000
        TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
        HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""
        
        if [ "$HAS_SWAP" -gt 0 ]; then
            SWAPPINESS=60 
            echo -e "${gl_huang}检测极小内存(${MEM_MB_VAL}MB)，启动调虎离山策略保护网络栈${gl_bai}"
            [ -f /sys/module/zswap/parameters/enabled ] && echo Y > /sys/module/zswap/parameters/enabled 2>/dev/null
        else
            echo -e "${gl_red}检测极小内存(${MEM_MB_VAL}MB)无Swap！已强制降级防死机，请加Swap！${gl_bai}"
        fi
    fi

    local KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then CC="bbr"; QDISC="fq"; fi
    fi

    local TCP_MEM_MIN=$((MEM_MB_VAL * 256))
    local TCP_MEM_DEF=$((MEM_MB_VAL * 512))
    local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384
    [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768

    # 动态注入直播 UDP 全局池
    if [ "$scene" = "stream" ] && [ "$MEM_MB_VAL" -ge 1024 ]; then
        STREAM_EXTRA="${STREAM_EXTRA}
net.ipv4.udp_mem = $((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    fi

    # 网站模式动态覆盖 TW_BUCKETS
    local TW_BUCKETS=$((SOMAXCONN * 4))
    local MAX_ORPHANS=$((SOMAXCONN * 2))
    if [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ]; then TW_BUCKETS=524288; fi
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    local backup_conf="${CONF}.bak.$(date +%s)"
    [ -f "$CONF" ] && cp "$CONF" "$backup_conf"
    local lock_file="/tmp/99-yw-optimize.lock"
    exec 200> "$lock_file"; flock -x 200
    
    cat > "$CONF" << EOF
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB_VAL}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ── TCP 拥塞控制 ──
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC

# ── TCP 缓冲区 ──
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

# ── UDP 缓冲区 (基础) ──
net.ipv4.udp_rmem_min = $UDP_RMEM_MIN
net.ipv4.udp_wmem_min = $UDP_RMEM_MIN

# ── 连接队列 ──
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# ── TCP 连接优化 ──
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

# ── 网络低延迟/防抖动特化 ──
net.ipv4.tcp_slow_start_after_idle = $TCP_SLOW_START_AFTER_IDLE
net.ipv4.tcp_ecn = $TCP_ECN

# ── 端口与内存 ──
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_DEF $TCP_MEM_MAX

# ── 虚拟内存 ──
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

# ── CPU/内核调度 ──
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
 $( [ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa_balancing 不支持" )

# ── 安全防护 ──
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

# ── 文件描述符 ──
fs.file-max = 1048576
fs.nr_open = 1048576

# ── 连接跟踪 ──
 $( if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))"
echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
else
echo "# conntrack 未启用"
fi )
 $HIGH_EXTRA
 $WEB_EXTRA
 $STREAM_EXTRA
 $GAME_EXTRA
 $BALANCED_EXTRA
EOF

    flock -u 200; exec 200>&-
    echo -e "${gl_lv}正在加载配置..."
    sysctl -p "$CONF" >/dev/null 2>&1
    
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize" >> /etc/security/limits.conf
        echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf
    fi
    ulimit -n 1048576 2>/dev/null
    check_swap; bbr_on

    echo -e "${gl_lv}✅ 验证结果:${gl_bai}"
    echo -e "   - 核心: \e[32m$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)\e[0m | 缓冲: \e[32m$((RMEM_MAX/1024/1024))MB\e[0m | Swap策略: \e[32m$SWAPPINESS\e[0m"
    echo -e "${gl_lv}✅ ${mode_name} 优化完成！${gl_bai}"
}

# ============================================================================
# BBRv3 & System Utils (精简合并，保持功能不变)
# ============================================================================

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then echo -e "${gl_hong}XanMod 已停止对当前系统($os_codename)支持${gl_bai}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    install wget gnupg ca-certificates || return 1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local psabi_level=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit}}' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3
    apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do local l="$psabi_level"; while [ "$l" -ge 1 ]; do local p="${prefix}-x64v${l}"; if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^ ]'; then printf '%s\n' "$p"; return 0; fi; l=$((l-1)); done; done
    return 1
}

bbrv3() {
    root_use
    if [ "$(uname -m)" = "aarch64" ]; then bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return 0; fi
    if [ -r /etc/os-release ]; then . /etc/os-release; if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then echo "仅支持Debian/Ubuntu"; return 0; fi; else return 0; fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do clear; echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"; read -e -p "选择: " c; case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; *) break ;; esac; done
    else
        clear; echo "设置BBR3 (仅Debian/Ubuntu)"; read -e -p "继续？: " c; [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot
    fi
}

restore_defaults() {
    echo -e "${gl_lv}还原中...${gl_bai}"; rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null; echo -e "${gl_lv}已还原${gl_bai}"
}

verify_network_status() {
    clear
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local mode="未知"
    case $rmem in
        8388608) mode="电竞级游戏模式 (8MB 绝杀缓冲)" ;;
        16777216) mode="通用游戏/中等内存 (16MB)" ;;
        4194304) mode="极限低内存保护 (4MB)" ;;
        67108864|134217728) 
            if sysctl -n net.core.netdev_budget 2>/dev/null | grep -q "1200"; then mode="直播推流模式 (64MB + 软中断加速)"
            elif sysctl -n vm.dirty_ratio 2>/dev/null | grep -q "40"; then mode="高性能下载模式 (64MB + IO聚簇)"
            else mode="高并发网站模式 (64MB + 极限TW池)"
            fi ;;
    esac
    echo -e "${gl_huang}========================================\n       智能模式识别验证\n========================================${gl_bai}"
    echo -e "算法: $(sysctl -n net.ipv4.tcp_congestion_control) | 队列: $(sysctl -n net.core.default_qdisc)"
    echo -e "防抖(ECN): $(sysctl -n net.ipv4.tcp_ecn) | 慢启动: $(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
    echo -e "最大TCP缓冲: $((rmem/1024/1024))MB"
    echo -e ">>> 智能鉴定结果: ${gl_lv}${mode}${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
}

show_sys_info() {
    while true; do
        clear
        local mem_info="$(awk '/MemAvailable/{printf "%dM/%dM", $2/1024, 0}' /proc/meminfo) $(awk '/MemTotal/{printf "(%dMB)", $2/1024}' /proc/meminfo)"
        local swap_info="$(free -m | awk '/Swap/{printf "%dM/%dM", $3, $2}')"
        echo -e "${gl_kjlan}系统信息${gl_bai}\n==============\n内存: $mem_info\nSwap: $swap_info\nIP: $(ip -4 addr | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | head -1)\n负载: $(uptime | awk '{print $(NF-2), $(NF-1), $NF}')\n运行: $(cat /proc/uptime | awk -F. '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60); if(d>0)printf("%d天 ",d);if(h>0)printf("%d时 ",h);printf("%d分\n",m)}')\n=============="
        echo -e "${gl_huang}1.管理Swap  0.返回${gl_bai}"
        read -e -p "选择: " c
        case $c in 1) change_swap_size ;; *) break ;; esac
    done
}

Kernel_optimize() {
    root_use
    while true; do
        clear
        local cur="未优化"
        [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        echo -e "${gl_lv}内核参数优化${gl_bai}\n当前: ${gl_huang}${cur:-系统优化已启用}${gl_bai}"
        echo -e "--------------------"
        echo -e "1. 高性能(下载/大文件): 极限IO聚簇写回，吞吐拉满"
        echo -e "2. 均衡优化: 稳定至上，内存安全锁"
        echo -e "3. 网站优化: 极限TW池，抗大促并发"
        echo -e "4. 直播推流: UDP极限拉爆+网卡软中断狂暴"
        echo -e "5. 游戏伺服: 8MB电竞级TCP防Bufferbloat"
        echo -e "6. BBRv3 内核安装"
        echo -e "7. 还原默认"
        echo -e "8. 远程自动调优"
        echo -e "9. 释放缓存"
        echo -e "10. 智能验证状态"
        echo "--------------------\n0. 返回"
        read -e -p "选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; tiaoyou_moshi="高性能优化"; _kernel_optimize_core "$tiaoyou_moshi" "high" ;;
            2) cd ~; clear; _kernel_optimize_core "均衡优化模式" "balanced" ;;
            3) cd ~; clear; tiaoyou_moshi="网站优化"; _kernel_optimize_core "$tiaoyou_moshi" "web" ;;
            4) cd ~; clear; tiaoyou_moshi="直播优化"; _kernel_optimize_core "$tiaoyou_moshi" "stream" ;;
            5) cd ~; clear; tiaoyou_moshi="游戏优化"; _kernel_optimize_core "$tiaoyou_moshi" "game" ;;
            6) cd ~; clear; bbrv3 ;;
            7) cd ~; clear; restore_defaults ;;
            8) read -e -p "回车拉取远程脚本..."; curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;;
            9) echo -e "${gl_red}警告：可能导致IO抖动！${gl_bai}"; read -e -p "确定释放？: " d; [[ "$d" =~ ^[Yy]$ ]] && sync && echo 3 > /proc/sys/vm/drop_caches && echo "已释放" ;;
            10) verify_network_status; read -rs -n 1 -p "按任意键..." ;;
            0|"") break ;;
        esac
    done
}

main_menu() {
    while true; do
        clear
        echo -e "${gl_huang}========================================\n       YW 系统管理与优化脚本\n========================================${gl_bai}"
        echo -e "${gl_lv}1. 系统信息查询\n${gl_huang}2. 内核参数优化 (BBR/特化)\n${gl_hui}0. 退出\n${gl_huang}========================================${gl_bai}"
        read -e -p "选择: " choice
        case $choice in 1) show_sys_info ;; 2) Kernel_optimize ;; 0) break ;; esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main_menu; fi
