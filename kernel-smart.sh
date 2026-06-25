#!/usr/bin/env bash
# ============================================================================
# Linux YW内核与网络调优模块 (YW全场景极限特化 + 中转网关专属)
# ============================================================================

# --- 邮色定义 ---
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
    if [ "$swap_total" -ge 512 ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
        return 0
    fi
    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then
        swapon /swapfile >/dev/null 2>&1
        swap_total=$(free -m | awk '/Swap/{print $2}')
        [ "$swap_total" -ge 512 ] && return 0
    fi
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${gl_huang}正在创建 512MB 应急 Swap...${gl_bai}"
        dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ 应急 Swap 创建完成。${gl_bai}"
    fi
}

auto_setup_zram() {
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
        echo -e "${gl_lv}检测到 zram 已在运行，跳过配置。${gl_bai}"
        return 0
    fi
    echo -e "${gl_lv}正在尝试自动配置 zram 替代 zswap...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then
            install zram-tools || return 1
        fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null
        sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1
        systemctl restart zramswap >/dev/null 2>&1
        if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
            echo -e "${gl_lv}✅ zram 配置成功并已启动（持久化生效）！${gl_bai}"
        else
            echo -e "${gl_huang}zram 服务启动失败，可能内核不支持。${gl_bai}"
        fi
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${gl_huang}CentOS/RHEL 建议手动执行: yum install zram-generator -y 并配置 systemd-zram-setup@zram0.service${gl_bai}"
    fi
}

check_disk_space() {
    local required_mb=$1
    local available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo -e "${gl_red}错误: 磁盘空间不足，需要 ${required_mb}MB，当前可用: ${gl_bai}${available_mb}MB"
        return 1
    fi
    return 0
}

install() {
    if command -v apt >/dev/null 2>&1; then
        if ! apt-get install -y "$@" >/tmp/yw_apt.log 2>&1; then echo -e "${gl_red}APT 失败:${gl_bai}"; tail -n 3 /tmp/yw_apt.log; return 1; fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y "$@" >/tmp/yw_yum.log 2>/dev/null; then echo -e "${gl_red}YUM 失败:${gl_bai}"; tail -n 3 /tmp/yw_yum.log; return 1; fi
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
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}        Swap 虚拟内存管理               ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "当前 Swap 大小: ${gl_lv}${current_swap} MB${gl_bai}"
    echo -e "磁盘剩余空间: $(df -m / | tail -1 | awk '{print $4}') MB"
    echo ""
    echo -e "请选择预设大小:"
    echo -e "1. 创建/增加到 1 GB"
    echo -e "2. 创建/增加到 2 GB"
    echo -e "3. 创建/增加到 4 GB"
    echo -e "4. 创建/增加到 6 GB"
    echo -e "5. 自定义大小 (MB)"
    echo -e "6. 移除当前 Swap (大小: ${current_swap} MB)"
    echo -e "0. 返回主菜单"
    echo -e "${gl_huang}========================================${gl_bai}"
    read -e -p "请输入选择: " swap_choice
    local swap_size=""
    case "$swap_choice" in
        1) swap_size=1024 ;; 2) swap_size=2048 ;; 3) swap_size=4096 ;; 4) swap_size=6144 ;;
        5) 
            read -e -p "请输入自定义大小 (MB, 最小512): " swap_size
            if [[ -z "$swap_size" || ! "$swap_size" =~ ^[0-9]+$ || "$swap_size" -lt 512 ]]; then
                echo -e "${gl_red}错误: 必须为纯数字且最小512MB${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0
            fi
            ;;
        6) if [ "$current_swap" -gt 0 ]; then swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"; sed -i '/swapfile.*swap/d' /etc/fstab; echo -e "${gl_lv}Swap 已移除${gl_bai}"; else echo -e "${gl_huang}当前没有 Swap 文件${gl_bai}"; fi; read -rs -n 1 -p "按任意键返回..." && return 0 ;;
        0|"") return 0 ;;
        *) echo -e "${gl_red}无效选择${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0 ;;
    esac
    if [ -n "$swap_size" ]; then
        local avail=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$avail" -lt $((swap_size + 100)) ]; then echo -e "${gl_red}磁盘空间不足${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0; fi
        echo -e "${gl_lv}正在创建 Swap 文件 (${swap_size}MB)...${gl_bai}"; swapoff "$swap_file" 2>/dev/null
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null; chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1; swapon "${swap_file}" >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ Swap 创建成功！当前大小: ${swap_size} MB${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# Core Optimization Logic
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
    local GAME_EXTRA="" STREAM_EXTRA="" HIGH_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA=""
    local TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0 

    case "$scene" in
        high)
            SWAPPINESS=10; OVERCOMMIT=1; VFS_PRESSURE=50; DIRTY_RATIO=40; DIRTY_BG_RATIO=10
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            HIGH_EXTRA=$'vm.dirty_ratio = 40\nvm.dirty_background_ratio = 10'
            ;;
        web)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3 
            WEB_EXTRA=$'net.ipv4.tcp_max_tw_buckets = 524288\nnet.ipv4.tcp_max_syn_backlog = 16384'
            ;;
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072
            STREAM_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000'
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=8388608; WMEM_MAX=8388608 
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=15 
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072
            GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480'
            ;;
        gateway)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=32768
            RMEM_MAX=8388608; WMEM_MAX=8388608 
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=100000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=30
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=16384
            GATEWAY_EXTRA=$'# ── 中转网关专属：保 CPU 算加密，不抢软中断 ──\nnet.core.optmem_max = 20480'
            ;;
        balanced)
            SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
            MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"
            SCHED_AUTOGROUP=0; THP="always"; NUMA=1; FIN_TIMEOUT=30
            KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5; TCP_SLOW_START_AFTER_IDLE=1
            BALANCED_EXTRA="vm.overcommit_memory = 0"
            ;;
        *) echo -e "${gl_red}错误: 未知场景${gl_bai}"; return 1 ;;
    esac

    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP=$(free -m | awk '/Swap/{print $2}')

    if [ "$MEM_MB_VAL" -ge 16384 ]; then
        MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 4096 ]; then
        MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then
        MIN_FREE_KB=32768
        if [ "$scene" != "balanced" ] && [ "$scene" != "game" ] && [ "$scene" != "gateway" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
        fi
        if [ "$scene" = "game" ] || [ "$scene" = "gateway" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
            GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072'
            GATEWAY_EXTRA=$'# ── 中转网关低内存自适应 ──'
        fi
    else
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10
        RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000
        TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
        HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""
        if [ -f /sys/module/zswap/parameters/enabled ]; then
            echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
        fi
        if [ "$HAS_SWAP" -gt 0 ]; then
            SWAPPINESS=60 
            echo -e "${gl_huang}检测极小内存(${MEM_MB_VAL}MB)，已自动禁用 zswap 防卡死。${gl_bai}"
            echo -e "${gl_lv}建议: 自动为您部署 zram 内存压缩盘...${gl_bai}"
            auto_setup_zram
        else
            echo -e "${gl_red}检测极小内存(${MEM_MB_VAL}MB)无Swap！已强制降级防死机。${gl_bai}"
            echo -e "${gl_lv}建议: 自动为您创建基础 Swap 并部署 zram...${gl_bai}"
            check_swap
            auto_setup_zram
        fi
    fi

    local KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then CC="bbr"; QDISC="fq"; fi
    fi

    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)); local TCP_MEM_DEF=$((MEM_MB_VAL * 512)); local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768

    if [ "$scene" = "stream" ] && [ "$MEM_MB_VAL" -ge 1024 ]; then
        STREAM_EXTRA="${STREAM_EXTRA}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    fi

    local TW_BUCKETS=$((SOMAXCONN * 4)); local MAX_ORPHANS=$((SOMAXCONN * 2))
    if [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ]; then TW_BUCKETS=524288; fi
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    local backup_conf="${CONF}.bak.$(date +%s)"; [ -f "$CONF" ] && cp "$CONF" "$backup_conf"
    local lock_file="/tmp/99-yw-optimize.lock"; exec 200> "$lock_file"; flock -x 200
    
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

# ── UDP 缓冲区 ──
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
 $GATEWAY_EXTRA
EOF

    flock -u 200; exec 200>&-
    echo -e "${gl_lv}正在加载配置..."
    
    local sysctl_err=$(sysctl -p "$CONF" 2>&1 | grep -v "Invalid argument" | grep -v "No such file or directory" | grep -v "unknown key")
    if [ -n "$sysctl_err" ]; then
        echo -e "${gl_huang}Sysctl 加载时有以下异常(通常不影响核心功能):${gl_bai}"
        echo "$sysctl_err" | head -n 3
    fi
    
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
# BBRv3 Management
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
    sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    if [ -f /sys/module/zswap/parameters/enabled ]; then
        echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
    fi
    sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled zramswap >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到由脚本部署的 zram，正在停止并取消开机自启...${gl_bai}"
        systemctl stop zramswap >/dev/null 2>&1
        systemctl disable zramswap >/dev/null 2>&1
    fi
    echo -e "${gl_lv}已还原所有设置（包括禁用 zram）${gl_bai}"
}

verify_network_status() {
    clear
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local mode="未知"
    case $rmem in
        8388608) 
            if sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null | grep -q "300"; then mode="中转网关模式 (8MB 防止卡顿+保隧道)"
            else mode="电竞级游戏模式 (8MB 绝杀缓冲)"
            fi ;;
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

# ============================================================================
# System Info Function
# ============================================================================

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
        local country=$(echo "$ipinfo" | awk -F'"' '/country/{print $4}')
        local city=$(echo "$ipinfo" | awk -F'"' '/city/{print $4}')
        local isp_info=$(echo "$ipinfo" | awk -F'"' '/org/{print $4}')
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
        local rx_gb=$(awk "BEGIN{printf \"%.2f\", ${rx}/1024/1024/1024/1024}")
        local tx_gb=$(awk "BEGIN{printf \"%.2f\", ${tx}/1024/1024/1024/1024}")
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

# ============================================================================
# Interactive Menu
# ============================================================================

Kernel_optimize() {
    root_use
    while true; do
        clear
        local cur="未优化"
        [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        echo -e "${gl_lv}Linux系统内核参数优化${gl_bai}"
        echo "------------------------------------------------"
        echo -e "当前模式: ${gl_huang}${cur:-系统优化已启用}${gl_bai}"
        echo -e "提供多种系统参数调优模式，用户可以根据自身使用场景进行选择切换。"
        echo -e "${gl_huang}提示: ${gl_bai}生产环境请谨慎使用！"
        echo -e "--------------------"
        echo -e "1. 高性能优化模式：     极限IO聚簇写回，吞吐拉满"
        echo -e "2. 均衡优化模式：       稳定至上，内存安全锁"
        echo -e "3. 网站优化模式：       极限TW池，抗大促并发"
        echo -e "4. 直播优化模式：       UDP极限拉爆+网卡软中断狂暴"
        echo -e "5. 游戏服优化模式：     8MB电竞级TCP防Bufferbloat"
        echo -e "6. 中转网关模式：       专精V2Ray/SS加密中转防卡顿 ${gl_huang}★${gl_bai}"
        echo -e "7. 还原默认设置：       将系统设置还原为默认配置。"
        echo -e "8. 自动调优：           根据测试数据自动调优内核参数。${gl_huang}★${gl_bai}"
        echo -e "9. 释放内存缓存：      强制清理系统 Cache (谨慎使用)"
        echo -e "10. 验证当前网络状态：  查看内核参数是否生效 ${gl_huang}★${gl_bai}"
        echo "--------------------"
        echo "0. 返回主菜单"
        echo "--------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; tiaoyou_moshi="高性能优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "high" ;;
            2) cd ~; clear; _kernel_optimize_core "均衡优化模式" "balanced" ;;
            3) cd ~; clear; tiaoyou_moshi="网站优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "web" ;;
            4) cd ~; clear; tiaoyou_moshi="直播优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "stream" ;;
            5) cd ~; clear; tiaoyou_moshi="游戏服优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "game" ;;
            6) cd ~; clear; tiaoyou_moshi="中转网关模式"; _kernel_optimize_core "$tiaoyou_moshi" "gateway" ;;
            7) cd ~; clear; restore_defaults ;;
            8) echo -e "${gl_huang}即将拉取并执行远程网络优化脚本..."; read -e -p "按回车键继续，或按 Ctrl+C 取消: "; curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;;
            9) echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动，生产环境请谨慎！${gl_bai}"; read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice; if [[ "$drop_choice" =~ ^[Yy]$ ]]; then sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"; else echo "已取消"; fi; read -rs -n 1 -p "按任意键继续..." ;;
            10) verify_network_status; read -rs -n 1 -p "按任意键返回菜单..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效的选择${gl_bai}" ; read -rs -n 1 -p "按任意键继续..." ;;
        esac
    done
}

# ============================================================================
# 模块 5：落地机节点管理面板
# ============================================================================

R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="\033[36m"; B="\033[97m"

get_my_ip() {
    local ip
    ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || \
         curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || \
         curl -4 -s -f --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    echo "${ip:-未知IP}"
}

select_sni() {
    echo -e "${Y}--- 伪装域名 (SNI) 设置 ---${R}" >&2
    echo -e "${G}1. 使用默认伪装域名${R}" >&2
    echo -e "${G}2. 自动优选最佳域名 (并发TLS握手测速)${R}" >&2
    echo -e "${G}3. 手动输入域名${R}" >&2
    read -e -p "请选择 (1默认 / 2优选 / 3手动): " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2)
            echo -e "${Y}[TLS 握手测速中，约需2秒]...${R}" >&2
            local d=("azure.microsoft.com" "bing.com" "www.icloud.com" "statici.icloud.com" "www.microsoft.com" "xp.apple.com" "vs.aws.amazon.com" "www.xbox.com" "snap.licdn.com" "www.oracle.com" "www.xilinx.com" "ts2.tc.mm.bing.net" "images.nvidia.com")
            local f="/tmp/sb_sni_test.$$"
            > "$f"
            for i in "${d[@]}"; do
                t1=$(date +%s%3N)
                if timeout 1 openssl s_client -connect "$i:443" -servername "$i" </dev/null &>/dev/null; then
                    t2=$(date +%s%3N)
                    echo "$((t2 - t1)) $i" >> "$f"
                else
                    echo "9999 $i" >> "$f"
                fi
            done
            local b_d="www.microsoft.com"
            local b_t=9999
            while read -r line; do
                local t=${line%% *}
                local dom=${line#* }
                if [ "$t" -lt "$b_t" ] 2>/dev/null; then
                    b_t=$t
                    b_d=$dom
                fi
            done < "$f"
            rm -f "$f"
            echo -e "${G}选用: $b_d (${b_t}ms)${R}" >&2
            echo "$b_d"
            ;;
        3) read -e -p "输入域名: " s; echo "${s:-www.apple.com}" ;;
        *) echo "www.apple.com" ;;
    esac
}

sb_check() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}请先安装 Sing-Box 核心！${R}"; return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}请先安装 jq (apt install jq -y)！${R}"; return 1
    fi
    return 0
}

sb_init_conf() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"
    fi
}

# 【关键修复】改为隐藏文件且不带 .json 后缀，防止被 sing-box 当作配置文件解析报错
META_FILE="/etc/sing-box/.nodes_meta"
OLD_META_FILE="/etc/sing-box/nodes_meta.json"

_init_meta_file() {
    # 自动清理以前遗留的会被 sing-box 误读的毒瘤文件
    if [ -f "$OLD_META_FILE" ]; then
        rm -f "$OLD_META_FILE"
    fi
    if [ ! -f "$META_FILE" ] || ! jq -e . "$META_FILE" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box
        echo '{}' > "$META_FILE"
    fi
}

_save_node_meta() {
    local port="$1" name="$2" type="$3" pub_key="${4:-}"
    _init_meta_file
    if [ -n "$pub_key" ]; then
        jq --arg p "$port" --arg n "$name" --arg t "$type" --arg pk "$pub_key" \
           '.[$p] = {"name": $n, "type": $t, "pub_key": $pk}' \
           "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
    else
        jq --arg p "$port" --arg n "$name" --arg t "$type" \
           '.[$p] = {"name": $n, "type": $t}' \
           "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
    fi
}

_del_node_meta() {
    local port="$1"
    [ ! -f "$META_FILE" ] && return
    jq --arg p "$port" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
}

_get_node_meta() {
    local port="$1" field="$2"
    [ ! -f "$META_FILE" ] && return
    jq -r --arg p "$port" '.[$p][$field] // empty' "$META_FILE"
}

open_port() {
    local port=$1 proto="${2:-tcp}" opened=0
    
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${port}/${proto} >/dev/null 2>&1 && opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then
            opened=1
        elif iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then
            opened=1
        fi
    fi

    if [ "$opened" -eq 1 ]; then
        echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}"
    else
        echo -e "${Y}  ⚠ 无法自动放行 ${proto^^} ${port}，请手动检查云安全组${R}"
    fi
}

sb_manage_menu() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || [ ! -s "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"
        systemctl stop sing-box >/dev/null 2>&1
    fi

    while true; do
        clear
        local sb_status="${RED}未安装${R}"
        if command -v sing-box >/dev/null 2>&1; then
            if [ -f "/etc/sing-box/config.json" ] && jq -e '.inbounds | length > 0' "/etc/sing-box/config.json" >/dev/null 2>&1; then
                if systemctl is-active --quiet sing-box 2>/dev/null; then 
                    sb_status="${G}运行中 ✅${R}"
                else 
                    sb_status="${Y}已停止${R}" 
                fi
            else
                sb_status="${Y}待配置 (无节点)${R}"
            fi
        fi

        echo -e "${G}========================================${R}"
        echo -e "${G}       Sing-Box 落地节点管理          ${R}"
        echo -e "${G}========================================${R}"
        echo -e "核心状态: ${sb_status}${R}"
        echo -e "${G}========================================${R}"
        echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
        echo -e "${G}2.${R} 添加 VLESS Reality 节点 (含优选SNI)"
        echo -e "${G}3.${R} 添加 Hysteria2 节点 (含优选SNI)"
        echo -e "${H}4.${R} 查看节点与链接"
        echo -e "${RED}5.${R} 删除节点 (按端口)"
        echo -e "${H}6.${R} 重启/停止/查看日志"
        echo -e "${Y}7.${R} 手动开放端口 (防火墙放行)"
        echo -e "${G}========================================${R}"
        echo -e "${H}0.${R} 返回主菜单"
        echo -e "${G}========================================${R}"
        
        read -e -p "请输入选择: " c
        case $c in
            1) 
                echo -e "${C}正在连接官方源安装...${R}"
                if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash
                elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash
                else echo -e "${RED}不支持该系统${R}"; fi
                read -rs -n 1 -p "按任意键继续..." ;;
            2) sb_add_reality ;;
            3) sb_add_hy2 ;;
            4) sb_view_nodes ;;
            5) sb_del_node ;;
            6)
                echo -e "${C}1.重启 2.停止 3.日志 (回车取消):${R}"
                read -e -p "选择: " act
                case $act in
                    1) systemctl restart sing-box && echo -e "${G}已重启${R}" ;;
                    2) systemctl stop sing-box && echo -e "${Y}已停止${R}" ;;
                    3) systemctl stop sing-box >/dev/null 2>&1; journalctl -u sing-box -n 30 --no-pager ;;
                esac
                read -rs -n 1 -p "按任意键继续..." ;;
            7)
                echo -e "${C}--- 手动开放端口 ---${R}"
                read -e -p "请输入要放行的端口号: " m_port
                if [[ ! "$m_port" =~ ^[0-9]{1,5}$ ]] || (( ${m_port#0} < 1 || ${m_port#0} > 65535 )); then
                    echo -e "${RED}端口无效，需为 1-65535 的数字${R}"
                else
                    echo -e "${Y}选择协议:${R}"
                    echo -e "${G}1.${R} TCP"; echo -e "${G}2.${R} UDP"; echo -e "${G}3.${R} TCP + UDP"
                    read -e -p "选择 (回车默认TCP): " m_proto
                    case "$m_proto" in
                        2) open_port "$m_port" "udp" ;;
                        3) open_port "$m_port" "tcp"; open_port "$m_port" "udp" ;;
                        *)  open_port "$m_port" "tcp" ;;
                    esac
                fi
                read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${RED}输入无效${R}"; sleep 1 ;;
        esac
    done
}

sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 VLESS Reality 落地节点 ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi

    local sni; sni=$(select_sni)

    echo -e "${Y}正在生成 UUID 和密钥对...${R}"
    local uuid priv_key pub_key keys
    uuid=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair 2>/dev/null)
    priv_key=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
    pub_key=$(echo "$keys" | grep PublicKey | awk '{print $2}')
    if [ -z "$pub_key" ]; then echo -e "${RED}密钥生成失败！${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi

    local default_name="Reality-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"

    jq --argjson p "$port" --arg u "$uuid" --arg pk "$priv_key" --arg s "$sni" \
       '.inbounds += [{"type":"vless","tag":"vless-in-$p","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk}}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "tcp"
        _save_node_meta "$port" "$node_name" "vless" "$pub_key"
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
            _del_node_meta "$port"
            read -rs -n 1 -p "按任意键返回..."
            return
        fi
        local my_ip; my_ip=$(get_my_ip)
        local link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}"
        echo -e "${G}✅ VLESS Reality 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
        sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================
# 端口跳跃辅助函数
# ============================================================

_save_hop_meta() {
    local port="$1" start="$2" end="$3" proto="$4"
    mkdir -p /etc/sing-box/meta
    cat > "/etc/sing-box/meta/hop_${port}.conf" <<EOF
HOP_START=${start}
HOP_END=${end}
HOP_PROTO=${proto}
EOF
}

_del_hop_meta() {
    local port="$1"
    rm -f "/etc/sing-box/meta/hop_${port}.conf"
}

_load_hop_meta() {
    local port="$1" f="/etc/sing-box/meta/hop_${port}.conf"
    [ -f "$f" ] && { source "$f"; echo "${HOP_START} ${HOP_END} ${HOP_PROTO}"; }
}

_persist_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    elif [ -f /etc/redhat-release ] && command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null
    fi
}

_add_port_hop() {
    local main_port="$1" hop_start="$2" hop_end="$3" proto="$4"
    local cmt="SINGBOX_HOP_${main_port}"

    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -t nat -C PREROUTING -p "${proto}" \
             --dport "${hop_start}:${hop_end}" \
             -j REDIRECT --to-ports "${main_port}" \
             -m comment --comment "${cmt}" 2>/dev/null; then
            iptables -t nat -A PREROUTING -p "${proto}" \
                --dport "${hop_start}:${hop_end}" \
                -j REDIRECT --to-ports "${main_port}" \
                -m comment --comment "${cmt}"
            echo -e "${G}  [iptables] ${hop_start}:${hop_end} -> ${main_port}${R}"
        fi
    elif command -v nft >/dev/null 2>&1; then
        nft list tables 2>/dev/null | grep -q "inet singbox_nat" || \
            nft add table inet singbox_nat
        nft list chains 2>/dev/null | grep -q "inet singbox_nat prerouting" || \
            nft 'add chain inet singbox_nat prerouting { type nat hook prerouting priority dstnat; }'
        nft add rule inet singbox_nat prerouting \
            "${proto}" dport "${hop_start}-${hop_end}" \
            redirect to ":${main_port}" comment "\"${cmt}\""
        echo -e "${G}  [nftables] ${hop_start}-${hop_end} -> ${main_port}${R}"
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${hop_start}-${hop_end}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow "${hop_start}:${hop_end}/${proto}" >/dev/null 2>&1
    fi

    _persist_iptables
}

_del_port_hop() {
    local main_port="$1" hop_start="$2" hop_end="$3" proto="$4"
    local cmt="SINGBOX_HOP_${main_port}"

    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p "${proto}" \
            --dport "${hop_start}:${hop_end}" \
            -j REDIRECT --to-ports "${main_port}" \
            -m comment --comment "${cmt}" 2>/dev/null
    elif command -v nft >/dev/null 2>&1; then
        local handle
        handle=$(nft -a list chain inet singbox_nat prerouting 2>/dev/null \
                 | grep "\"${cmt}\"" | grep -oP 'handle \K[0-9]+')
        [ -n "$handle" ] && nft delete rule inet singbox_nat prerouting handle "$handle" 2>/dev/null
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${hop_start}-${hop_end}/${proto}" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${hop_start}:${hop_end}/${proto}" >/dev/null 2>&1
    fi

    _persist_iptables
}

# 零参数调用，自动从 meta 文件读取并清理
_cleanup_port_hop() {
    local port="$1" info
    info=$(_load_hop_meta "$port")
    [ -z "$info" ] && return
    local hop_start hop_end hop_proto
    read -r hop_start hop_end hop_proto <<< "$info"
    echo -e "${Y}正在清理端口跳跃规则 (${hop_start}-${hop_end})...${R}"
    _del_port_hop "$port" "$hop_start" "$hop_end" "$hop_proto"
    _del_hop_meta "$port"
}

# ============================================================
# sb_add_hy2（替换原函数）
# ============================================================
sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    if ! command -v openssl >/dev/null 2>&1; then echo -e "${RED}请先安装 openssl！${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    echo -e "${C}--- 添加 Hysteria2 落地节点 ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (1-65535)${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi

    # ---- 端口跳跃 ----
    local hop_start="" hop_end="" enable_hop="n"
    read -e -p "是否启用端口跳跃? [y/N]: " enable_hop
    if [[ "$enable_hop" =~ ^[Yy]$ ]]; then
        read -e -p "跳跃起始端口: " hop_start
        read -e -p "跳跃结束端口: " hop_end
        if [[ ! "$hop_start" =~ ^[0-9]+$ ]] || [[ ! "$hop_end" =~ ^[0-9]+$ ]] \
           || [ "$hop_start" -lt 1 ] || [ "$hop_end" -gt 65535 ] \
           || [ "$hop_start" -ge "$hop_end" ]; then
            echo -e "${RED}端口范围错误，需为 1-65535 且起始 < 结束${R}"
            read -rs -n 1 -p "按任意键返回..."; return
        fi
        if [ "$port" -ge "$hop_start" ] && [ "$port" -le "$hop_end" ]; then
            echo -e "${RED}主端口 ${port} 不能在跳跃范围 ${hop_start}-${hop_end} 内${R}"
            read -rs -n 1 -p "按任意键返回..."; return
        fi
        echo -e "${H}将跳跃 $((hop_end - hop_start + 1)) 个端口: ${hop_start} ~ ${hop_end} -> ${port}${R}"
    fi

    local sni; sni=$(select_sni)

    echo -e "${Y}正在生成密码和自签证书...${R}"
    local pass; pass=$(openssl rand -base64 16)
    local crt="/etc/sing-box/hy2_${port}.crt" key="/etc/sing-box/hy2_${port}.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=$sni" -days 3650 2>/dev/null
    fi
    chmod 600 "$key" 2>/dev/null; chmod 644 "$crt" 2>/dev/null

    local default_name="Hy2-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"

    jq --argjson p "$port" --arg pass "$pass" --arg s "$sni" --arg crt "$crt" --arg key "$key" \
       '.inbounds += [{"type":"hysteria2","tag":"hy2-in-$p","listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$s,"certificate_path":$crt,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "udp"

        if [[ "$enable_hop" =~ ^[Yy]$ ]]; then
            echo -e "${Y}正在设置端口跳跃规则...${R}"
            _add_port_hop "$port" "$hop_start" "$hop_end" "udp"
            _save_hop_meta "$port" "$hop_start" "$hop_end" "udp"
        fi

        _save_node_meta "$port" "$node_name" "hysteria2"
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
            rm -f "$crt" "$key"
            _del_node_meta "$port"
            [[ "$enable_hop" =~ ^[Yy]$ ]] && { _del_port_hop "$port" "$hop_start" "$hop_end" "udp"; _del_hop_meta "$port"; }
            read -rs -n 1 -p "按任意键返回..."
            return
        fi
        local my_ip; my_ip=$(get_my_ip)
        local link
        if [[ "$enable_hop" =~ ^[Yy]$ ]]; then
            link="hysteria2://${pass}@${my_ip}:${hop_start}-${hop_end}?insecure=1&sni=${sni}#${node_name}"
        else
            link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#${node_name}"
        fi
        echo -e "${G}✅ Hysteria2 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
        if [[ "$enable_hop" =~ ^[Yy]$ ]]; then
            echo -e "${H}提示: 端口跳跃 ${hop_start}-${hop_end} -> ${port}，请确保云安全组已放行 UDP ${hop_start}-${hop_end}${R}"
        else
            echo -e "${H}注意: Hysteria2 是 UDP 协议，请确保云安全组也已放行 UDP ${port}${R}"
        fi
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
        rm -f "$crt" "$key"
        [[ "$enable_hop" =~ ^[Yy]$ ]] && { _del_port_hop "$port" "$hop_start" "$hop_end" "udp"; _del_hop_meta "$port"; }
        sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    local conf="/etc/sing-box/config.json"
    local inbounds; inbounds=$(jq -c '.inbounds[]' "$conf" 2>/dev/null)
    if [ -z "$inbounds" ]; then echo -e "${H}暂无节点可删除${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi

    clear
    echo -e "${RED}========================================${R}"
    echo -e "${RED}         删除节点                       ${R}"
    echo -e "${RED}========================================${R}"

    local meta_json; meta_json=$(cat "$META_FILE" 2>/dev/null || echo '{}')
    local idx=1
    echo "$inbounds" | while IFS= read -r in; do
        local type port node_name
        type=$(echo "$in" | jq -r '.type')
        port=$(echo "$in" | jq -r '.listen_port')
        node_name=$(echo "$meta_json" | jq -r --arg p "$port" '.[$p].name // "未命名"')
        echo -e "${C}[${idx}]${R} ${Y}${node_name}${R} | 协议: ${type} | 端口: ${port}"
        idx=$((idx + 1))
    done
    echo -e "${RED}========================================${R}"
    read -e -p "请输入要删除的节点端口号 (回车取消): " del_port
    if [[ -z "$del_port" || ! "$del_port" =~ ^[0-9]+$ ]]; then
        echo -e "${Y}已取消${R}"
    else
        local target_idx=$(jq -r --arg p "$del_port" '.inbounds | to_entries[] | select(.value.listen_port == ($p|tonumber)) | .key' "$conf")
        if [ -z "$target_idx" ]; then
            echo -e "${RED}未找到端口为 ${del_port} 的节点${R}"
        else
            cp "$conf" "${conf}.bak.$(date +%s)"
            local is_hy2=$(jq -r --argjson idx "$target_idx" '.inbounds[$idx].type' "$conf")
            jq --argjson idx "$target_idx" 'del(.inbounds[$idx])' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
            
            if [ "$is_hy2" = "hysteria2" ]; then
                rm -f "/etc/sing-box/hy2_${del_port}.crt" "/etc/sing-box/hy2_${del_port}.key"
            fi
            
            _del_node_meta "$del_port"
            _cleanup_port_hop "$del_port"
            
            if jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1; then
                systemctl restart sing-box
                sleep 2
                if systemctl is-active --quiet sing-box 2>/dev/null; then
                    echo -e "${G}✅ 节点已删除，服务已重启运行${R}"
                else
                    echo -e "${Y}⚠ 节点已删除，但服务重启失败，日志如下：${R}"
                    journalctl -u sing-box -n 10 --no-pager
                fi
            else
                systemctl stop sing-box >/dev/null 2>&1
                echo -e "${Y}已删除最后一个节点，服务已停止。${R}"
            fi
        fi
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 主入口
# ============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${gl_lv}========================================${gl_bai}"
        echo -e "${gl_lv}        YW 系统优化与管理面板           ${gl_bai}"
        echo -e "${gl_lv}========================================${gl_bai}"
        echo -e "${gl_kjlan}1.${gl_bai} 系统信息查询"
        echo -e "${gl_kjlan}2.${gl_bai} 安装 BBRv3 内核"
        echo -e "${gl_kjlan}3.${gl_bai} Linux系统内核参数优化"
        echo -e "${gl_kjlan}4.${gl_bai} Sing-Box 落地节点管理"
        echo -e "${gl_kjlan}5.${gl_bai} 管理虚拟内存"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_huang}0.${gl_bai} 退出脚本"
        echo -e "${gl_lv}========================================${gl_bai}"
        read -e -p "请输入选择: " main_choice
        case $main_choice in
            1) show_sys_info ;;
            2) bbrv3 ;;
            3) Kernel_optimize ;;
            4) sb_manage_menu ;;
            5) change_swap_size ;;
            0|"") clear; exit 0 ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

main_menu
