#!/usr/bin/env bash
# ============================================================================
# Linux YW 内核与网络调优 (直播特化 + 游戏辅修 + 直连 + Hy2端口跳跃)
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_hong:=\033[31m}"
: "${gl_kjlan:=\033[32m}"
R="$gl_bai"; G="$gl_lv"; Y="$gl_huang"; H="$gl_hui"; RED="$gl_red"; C="\033[36m"; B="\033[97m"

# --- 全局变量 ---
: "${gh_proxy:=https://}"

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
    local swap_total
    swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -ge 512 ] 2>/dev/null || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
        return 0
    fi
    if [ -f /swapfile ] && [ "${swap_total:-0}" -lt 512 ] 2>/dev/null; then
        swapon /swapfile >/dev/null 2>&1
        swap_total=$(free -m | awk '/Swap/{print $2}')
        [ "${swap_total:-0}" -ge 512 ] && return 0
    fi
    if df / 2>/dev/null | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
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
        echo -e "${gl_lv}检测到 zram 已在运行，跳过配置。${gl_bai}"; return 0
    fi
    echo -e "${gl_lv}正在尝试自动配置 zram 替代 zswap...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then
            apt-get install -y zram-tools >/dev/null 2>&1 || return 1
        fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null
        sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1
        if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
            echo -e "${gl_lv}✅ zram 配置成功并已启动！${gl_bai}"
        else
            echo -e "${gl_huang}zram 服务启动失败，可能内核不支持。${gl_bai}"
        fi
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${gl_huang}CentOS/RHEL 建议手动执行: yum install zram-generator -y${gl_bai}"
    fi
}

check_disk_space() {
    local required_mb=$1; local available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$available_mb" -lt "$required_mb" ] 2>/dev/null; then
        echo -e "${gl_red}错误: 磁盘空间不足，需要 ${required_mb}MB，当前可用: ${gl_bai}${available_mb}MB"
        return 1
    fi
    return 0
}

install() {
    if command -v apt >/dev/null 2>&1; then
        if ! apt-get install -y "$@" >/tmp/yw_apt.log 2>&1; then
            echo -e "${gl_red}APT 失败:${gl_bai}"; tail -n 3 /tmp/yw_apt.log; return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y "$@" >/tmp/yw_yum.log 2>/dev/null; then
            echo -e "${gl_red}YUM 失败:${gl_bai}"; tail -n 3 /tmp/yw_yum.log; return 1
        fi
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

# ============================================================================
# Swap Management
# ============================================================================

change_swap_size() {
    local swap_file="/swapfile"
    local current_swap; current_swap=$(free -m | awk '/Swap/{print $2}')
    clear
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}        Swap 虚拟内存管理               ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "当前 Swap 大小: ${gl_lv}${current_swap} MB${gl_bai}"
    echo -e "磁盘剩余空间: $(df -m / | tail -1 | awk '{print $4}') MB"
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
            fi ;;
        6)
            if [ "${current_swap:-0}" -gt 0 ]; then
                swapoff "$swap_file" 2>/dev/null; rm -f "$swap_file"
                sed -i '/swapfile.*swap/d' /etc/fstab; echo -e "${gl_lv}Swap 已移除${gl_bai}"
            else echo -e "${gl_huang}当前没有 Swap 文件${gl_bai}"; fi
            read -rs -n 1 -p "按任意键返回..." && return 0 ;;
        0|"") return 0 ;;
        *) echo -e "${gl_red}无效选择${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0 ;;
    esac
    if [ -n "$swap_size" ]; then
        local avail; avail=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$avail" -lt $((swap_size + 100)) ]; then
            echo -e "${gl_red}磁盘空间不足${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0
        fi
        echo -e "${gl_lv}正在创建 Swap 文件 (${swap_size}MB)...${gl_bai}"; swapoff "$swap_file" 2>/dev/null
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null; chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1; swapon "${swap_file}" >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ Swap 创建成功！当前大小: ${swap_size} MB${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# Core Kernel Optimization
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"; local scene="${2:-stream}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}正在应用${mode_name}参数...${gl_bai}"

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE
    local SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN UDP_WMEM_MIN UDP_RMEM_MAX UDP_WMEM_MAX
    local TCP_NOTSENT_LOWAT TCP_FASTOPEN TCP_TW_REUSE TCP_MTU_PROBING
    local TCP_SLOW_START_AFTER_IDLE TCP_ECN TCP_THIN_LINEAR_TIMEOUTS TCP_NO_METRICS_SAVE TCP_FRTO
    local NETDEV_BUDGET NETDEV_MAX_BACKLOG SCENE_EXTRA="" MEMORY_TIER=""

    case "$scene" in
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144; UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0; TCP_THIN_LINEAR_TIMEOUTS=1; TCP_NO_METRICS_SAVE=1; TCP_FRTO=0
            NETDEV_BUDGET=1200; NETDEV_MAX_BACKLOG=500000
            SCENE_EXTRA=$'net.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1'
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=8388608; WMEM_MAX=8388608
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3
            UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144; UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0; TCP_THIN_LINEAR_TIMEOUTS=1; TCP_NO_METRICS_SAVE=1; TCP_FRTO=0
            NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
            SCENE_EXTRA=$'net.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.core.optmem_max = 20480'
            ;;
        direct)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144; UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0; TCP_THIN_LINEAR_TIMEOUTS=0; TCP_NO_METRICS_SAVE=0; TCP_FRTO=1
            NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
            SCENE_EXTRA=$'net.ipv4.tcp_frto = 1\nnet.ipv4.udp_mem = 65536 131072 262144'
            ;;
        *) echo -e "${gl_red}错误: 未知场景${gl_bai}"; return 1 ;;
    esac

    local MEM_MB_VAL; MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP; HAS_SWAP=$(free -m | awk '/Swap/{print $2}')

    if [ "$MEM_MB_VAL" -ge 16384 ] 2>/dev/null; then
        MIN_FREE_KB=131072; SWAPPINESS=5; MEMORY_TIER="大内存全量"
    elif [ "$MEM_MB_VAL" -ge 4096 ] 2>/dev/null; then
        MIN_FREE_KB=65536; MEMORY_TIER="中等内存"
    elif [ "$MEM_MB_VAL" -ge 1024 ] 2>/dev/null; then
        MIN_FREE_KB=32768; MEMORY_TIER="小内存自适应"
        case "$scene" in
            stream|direct)
                RMEM_MAX=16777216; WMEM_MAX=16777216
                TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
                NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
                UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144; UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
                SCENE_EXTRA=$'# ── 直播/直连小内存 ──\nnet.ipv4.udp_rmem_min = 262144\nnet.ipv4.udp_wmem_min = 262144\nnet.ipv4.udp_rmem_max = 268435456\nnet.ipv4.udp_wmem_max = 268435456\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 250000\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.udp_mem = 32768 65536 131072'
                [ "$scene" = "direct" ] && SCENE_EXTRA="${SCENE_EXTRA}"$'\nnet.ipv4.tcp_frto = 1'
                ;;
            game)
                RMEM_MAX=8388608; WMEM_MAX=8388608
                TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
                NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
                UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144; UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
                SCENE_EXTRA=$'# ── 游戏小内存 ──\nnet.ipv4.udp_rmem_min = 262144\nnet.ipv4.udp_wmem_min = 262144\nnet.ipv4.udp_rmem_max = 268435456\nnet.ipv4.udp_wmem_max = 268435456\nnet.core.optmem_max = 20480\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.ipv4.udp_mem = 32768 65536 131072'
                ;;
        esac
    else
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10; SOMAXCONN=2048; BACKLOG=2000; SYN_BACKLOG=2048; MEMORY_TIER="极小内存保命"
        if [ -f /sys/module/zswap/parameters/enabled ]; then echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; fi
        if [ "${HAS_SWAP:-0}" -gt 0 ] 2>/dev/null; then
            SWAPPINESS=60; echo -e "${gl_huang}检测极小内存(${MEM_MB_VAL}MB)，已禁用zswap。${gl_bai}"; auto_setup_zram
        else
            echo -e "${gl_red}检测极小内存(${MEM_MB_VAL}MB)无Swap！${gl_bai}"; check_swap; auto_setup_zram
        fi
        case "$scene" in
            stream|direct)
                RMEM_MAX=4194304; WMEM_MAX=4194304; TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
                UDP_RMEM_MIN=131072; UDP_WMEM_MIN=131072; UDP_RMEM_MAX=33554432; UDP_WMEM_MAX=33554432
                NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=50000
                SCENE_EXTRA=$'# ── 极小内存保命 ──\nnet.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 33554432\nnet.ipv4.udp_wmem_max = 33554432\nnet.core.netdev_budget = 300\nnet.core.netdev_max_backlog = 50000\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.udp_mem = 16384 32768 65536'
                [ "$scene" = "direct" ] && SCENE_EXTRA="${SCENE_EXTRA}"$'\nnet.ipv4.tcp_frto = 1'
                ;;
            game)
                RMEM_MAX=4194304; WMEM_MAX=4194304; TCP_RMEM="4096 16384 4194304"; TCP_WMEM="4096 16384 4194304"
                UDP_RMEM_MIN=131072; UDP_WMEM_MIN=131072; UDP_RMEM_MAX=33554432; UDP_WMEM_MAX=33554432
                NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=50000
                SCENE_EXTRA=$'# ── 游戏极小内存 ──\nnet.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 33554432\nnet.ipv4.udp_wmem_max = 33554432\nnet.core.optmem_max = 10240\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.ipv4.udp_mem = 16384 32768 65536'
                ;;
        esac
    fi

    local KVER; KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then CC="bbr"; QDISC="fq"; fi
    fi

    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)); local TCP_MEM_DEF=$((MEM_MB_VAL * 512)); local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384
    [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    local TW_BUCKETS=$((SOMAXCONN * 4)); local MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    local backup_conf="${CONF}.bak.$(date +%s)"; [ -f "$CONF" ] && cp "$CONF" "$backup_conf"
    cat > "$CONF" << SYSEOF
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene | 内存段: $MEMORY_TIER
# 内存: ${MEM_MB_VAL}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN:-16384}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN:-16384}
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
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
net.ipv4.tcp_no_metrics_save = $TCP_NO_METRICS_SAVE
net.ipv4.tcp_frto = $TCP_FRTO
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_DEF $TCP_MEM_MAX
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
 $( [ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa_balancing 不支持" )
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
SYSEOF
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        cat >> "$CONF" << SYSEOF
net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
SYSEOF
    else echo "# conntrack 未启用" >> "$CONF"; fi
    [ -n "$SCENE_EXTRA" ] && echo -e "\n$SCENE_EXTRA" >> "$CONF"

    echo -e "${gl_lv}正在加载配置...${gl_bai}"
    local sysctl_err; sysctl_err=$(sysctl -p "$CONF" 2>&1 | grep -v "Invalid argument" | grep -v "No such file or directory" | grep -v "unknown key")
    [ -n "$sysctl_err" ] && { echo -e "${gl_huang}Sysctl 异常:${gl_bai}"; echo "$sysctl_err" | head -n 3; }
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize\n* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf
    fi
    ulimit -n 1048576 2>/dev/null; check_swap; bbr_on
    echo -e "${gl_lv}✅ 验证结果:${gl_bai}"
    echo -e "   - 内存段: \e[33m${MEMORY_TIER} (${MEM_MB_VAL}MB)\e[0m"
    echo -e "   - 核心: \e[32m${CC}\e[0m | TCP缓冲: \e[32m$((RMEM_MAX/1024/1024))MB\e[0m | UDP最小: \e[32m$((UDP_RMEM_MIN/1024))KB\e[0m"
    echo -e "${gl_lv}✅ ${mode_name} 优化完成！${gl_bai}"
}

# ============================================================================
# BBRv3 / 还原 / 验证
# ============================================================================
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg" list_file="/etc/apt/sources.list.d/xanmod-release.list" os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then echo -e "${gl_hong}XanMod 已停止对当前系统支持${gl_bai}"; return 1; fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    install wget gnupg ca-certificates || return 1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}
xanmod_detect_package() {
    local psabi_level; psabi_level=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit}}' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] 2>/dev/null && psabi_level=3; apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do local l="$psabi_level"; while [ "$l" -ge 1 ]; do local p="${prefix}-x64v${l}"; if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^ ]'; then printf '%s\n' "$p"; return 0; fi; l=$((l-1)); done; done; return 1
}
bbrv3() {
    root_use
    if [ "$(uname -m)" = "aarch64" ]; then bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return 0; fi
    if [ -r /etc/os-release ]; then . /etc/os-release; if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then echo "仅支持Debian/Ubuntu"; return 0; fi; else return 0; fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do clear; echo "当前: $(uname -r)"; echo "1.更新 2.卸载 0.返回"; read -e -p "选择: " c; case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade "$(xanmod_detect_package)" && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; *) break ;; esac; done
    else clear; echo "设置BBR3 (仅Debian/Ubuntu)"; read -e -p "继续？: " c; if [[ "$c" =~ ^[Yy]$ ]]; then check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y "$(xanmod_detect_package)" && bbr_on && server_reboot; fi; fi
}
restore_defaults() {
    echo -e "${gl_lv}还原中...${gl_bai}"; rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
    sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled zramswap >/dev/null 2>&1; then systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; fi
    echo -e "${gl_lv}已还原所有设置${gl_bai}"
}
verify_network_status() {
    clear; local rmem udp_min budget mode="未知" mem_mb; mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null); udp_min=$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null); budget=$(sysctl -n net.core.netdev_budget 2>/dev/null)
    local frto; frto=$(sysctl -n net.ipv4.tcp_frto 2>/dev/null)
    case $rmem in
        4194304) [ "$udp_min" -ge 131072 ] 2>/dev/null && mode="直播/直连/游戏 (极小内存自适应)" || mode="直连模式 (极小内存)" ;;
        8388608) mode="电竞游戏模式 (TCP 8MB 防Bufferbloat)" ;;
        16777216) [ "$udp_min" -ge 262144 ] 2>/dev/null && mode="直播/直连 (小内存, TCP 16MB + UDP拉满)" || mode="通用模式 (16MB)" ;;
        134217728) [ "$budget" -ge 1200 ] 2>/dev/null && mode="直播推流极限 (TCP 64MB + 软中断狂暴)" || mode="直连推流 (TCP 64MB, F-RTO=$frto)" ;;
    esac
    echo -e "${gl_huang}========================================\n       智能模式识别验证\n========================================${gl_bai}"
    echo -e "内存: ${mem_mb}MB | 算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | 队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo -e "TCP缓冲: $((rmem/1024/1024))MB | UDP最小: $((udp_min/1024))KB | F-RTO: ${frto}"
    echo -e ">>> 鉴定结果: ${gl_lv}${mode}${gl_bai}\n${gl_huang}========================================${gl_bai}"
}

# ============================================================================
# 系统信息查询 (原版完整版)
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

# ============================================================================
# SNI 优选
# ============================================================================
get_my_ip() {
    local ip; ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://api.ipify.org 2>/dev/null); echo "${ip:-未知IP}"
}
_test_tls_once() {
    local host="$1" t1 t2 ms; t1=$(date +%s%3N 2>/dev/null)
    if timeout 2 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
        t2=$(date +%s%3N 2>/dev/null); ms=$((t2 - t1)); [ "$ms" -ge 0 ] 2>/dev/null && echo "$ms" || echo "9999"
    else echo "9999"; fi
}
select_sni() {
    echo -e "${Y}--- 伪装域名 (SNI) 设置 ---${R}" >&2
    echo -e "${G}1. 使用默认${R} | ${G}2. 优选SNI (串行精确测速)${R} | ${G}3. 手动输入${R}" >&2
    read -e -p "选择: " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2)
            local d=("azure.microsoft.com" "bing.com" "www.icloud.com" "statici.icloud.com" "www.microsoft.com" "xp.apple.com" "vs.aws.amazon.com" "www.xbox.com" "snap.licdn.com" "www.oracle.com" "www.xilinx.com" "ts2.tc.mm.bing.net" "images.nvidia.com" "speed.cloudflare.com" "workers.cloudflare.com" "www.lovelive-anime.jp")
            local f="/tmp/sb_sni_test.$$"; : > "$f"
            echo -e "${Y}[第1轮] 串行测速 16 个域名...${R}" >&2; local idx=1
            for i in "${d[@]}"; do local ms; ms=$(_test_tls_once "$i"); echo "${ms} ${i}" >> "$f"; echo -ne "  ${gl_hui}[${idx}/${#d[@]}]${R} ${i}: $([ "$ms" -lt 9999 ] 2>/dev/null && echo "${G}${ms}ms${R}" || echo "${RED}超时${R}")\r" >&2; idx=$((idx+1)); done; echo "" >&2
            local top5; top5=$(sort -n "$f" | head -5)
            echo -e "${Y}[第2轮] 前5名各测3轮取最小...${R}" >&2; local f2="/tmp/sb_sni_test2.$$"; : > "$f2"
            while IFS=' ' read -r ms dom; do
                local best=9999 r; for r in 1 2 3; do local m; m=$(_test_tls_once "$dom"); [ "$m" -lt "$best" ] 2>/dev/null && best=$m; done
                echo "${best} ${dom}" >> "$f2"; echo -e "  ${dom}: $([ "$best" -lt 9999 ] 2>/dev/null && echo "${G}${best}ms${R}" || echo "${RED}超时${R}") (首轮${ms}ms)" >&2
            done <<< "$top5"
            local b_d="www.microsoft.com" b_t=9999; while IFS=' ' read -r t dom; do [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null && { b_t=$t; b_d="$dom"; }; done < "$f2"
            rm -f "$f" "$f2"; echo "" >&2; echo -e "${G}✅ 优选: ${b_d} (${b_t}ms)${R}" >&2; echo "$b_d"
            ;;
        3) read -e -p "域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

# ============================================================================
# Sing-Box 基础 & 元数据
# ============================================================================
sb_check() {
    if ! command -v sing-box >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box 核心！${R}"; return 1; fi
    if ! command -v jq >/dev/null 2>&1; then echo -e "${RED}请先安装 jq！${R}"; return 1; fi
    return 0
}
sb_init_conf() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then mkdir -p /etc/sing-box; echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"; fi
}
META_FILE="/etc/sing-box/.nodes_meta"
_init_meta_file() {
    [ -f "/etc/sing-box/nodes_meta.json" ] && rm -f "/etc/sing-box/nodes_meta.json"
    if [ ! -f "$META_FILE" ] || ! jq -e . "$META_FILE" >/dev/null 2>&1; then mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"; fi
}
_save_node_meta() {
    local port="$1" name="$2" type="$3" pub_key="${4:-}" hop_ports="${5:-}"
    _init_meta_file
    jq --arg p "$port" --arg n "$name" --arg t "$type" --arg pk "$pub_key" --arg hp "$hop_ports" \
       '.[$p] = {name: $n, type: $t, pub_key: (if $pk != "" then $pk else null end), hop_ports: (if $hp != "" then $hp else null end)} | .[$p] |= del(.[] | select(. == null))' \
       "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
}
_del_node_meta() {
    local port="$1"; [ ! -f "$META_FILE" ] && return
    jq --arg p "$port" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
}

# ============================================================================
# 防火墙 (支持范围)
# ============================================================================
open_port() {
    local port="$1" proto="${2:-tcp}" action="${3:-open}" opened=0
    local fc_port; fc_port=$(echo "$port" | sed 's/:/-/')
    if [ "$action" = "open" ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${fc_port}/${proto}" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 && opened=1
        elif command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && opened=1 || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && opened=1
        fi
        [ "$opened" -eq 1 ] && echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}" || echo -e "${Y}  ⚠ 无法自动放行 ${proto^^} ${port}，请手动检查云安全组${R}"
    else
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --remove-port="${fc_port}/${proto}" >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 && opened=1
        elif command -v iptables >/dev/null 2>&1; then
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && opened=1
        fi
        [ "$opened" -eq 1 ] && echo -e "${Y}  ⚠ 已关闭 ${proto^^} ${port}${R}"
    fi
}

# ============================================================================
# Sing-Box 管理菜单
# ============================================================================
sb_manage_menu() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || [ ! -s "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box; echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"; systemctl stop sing-box >/dev/null 2>&1
    fi
    while true; do
        clear; local sb_status="${RED}未安装${R}"
        if command -v sing-box >/dev/null 2>&1; then
            if [ -f "$conf" ] && jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1; then
                systemctl is-active --quiet sing-box 2>/dev/null && sb_status="${G}运行中 ✅${R}" || sb_status="${Y}已停止${R}"
            else sb_status="${Y}待配置${R}"; fi
        fi
        echo -e "${G}========================================${R}"
        echo -e "       Sing-Box 落地节点管理          "
        echo -e "${G}========================================${R}"
        echo -e "核心状态: ${sb_status}"
        echo -e "${G}========================================${R}"
        echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
        echo -e "${G}2.${R} 添加 VLESS Reality (优选SNI)"
        echo -e "${G}3.${R} 添加 Hysteria2 (优选SNI+端口跳跃)"
        echo -e "${C}4.${R} 添加 AnyTLS (需域名+证书)"
        echo -e "${H}5.${R} 查看节点与链接"
        echo -e "${RED}6.${R} 删除节点"
        echo -e "${H}7.${R} 重启/停止/日志"
        echo -e "${Y}8.${R} 手动开放端口"
        echo -e "${G}========================================${R}"
        echo -e "${H}0.${R} 返回"
        echo -e "${G}========================================${R}"
        read -e -p "选择: " c
        case $c in
            1) echo -e "${C}正在安装...${R}"; if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash; elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash; else echo -e "${RED}不支持${R}"; fi; read -rs -n 1 -p "继续..." ;;
            2) sb_add_reality ;; 3) sb_add_hy2 ;; 4) sb_add_anytls ;; 5) sb_view_nodes ;; 6) sb_del_node ;;
            7) echo -e "${C}1.重启 2.停止 3.日志:${R}"; read -e -p "选择: " act; case $act in 1) systemctl restart sing-box && echo -e "${G}已重启${R}" ;; 2) systemctl stop sing-box ;; 3) journalctl -u sing-box -n 30 --no-pager ;; esac; read -rs -n 1 -p "继续..." ;;
            8) read -e -p "端口号: " m_port; if [[ "$m_port" =~ ^[0-9]+$ ]]; then open_port "$m_port" "tcp"; else echo -e "${RED}无效${R}"; fi; read -rs -n 1 -p "继续..." ;;
            0|"") break ;; *) echo -e "${RED}无效${R}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 添加 VLESS Reality
# ============================================================================
sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 VLESS Reality ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    local sni; sni=$(select_sni)
    echo -e "${Y}生成密钥对...${R}"
    local uuid priv_key pub_key keys; uuid=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair 2>/dev/null)
    priv_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}'); pub_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
    if [ -z "$pub_key" ]; then echo -e "${RED}密钥生成失败${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    local default_name="Reality-${port}"; read -e -p "名称 (回车默认 ${default_name}): " node_name; [ -z "$node_name" ] && node_name="$default_name"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg u "$uuid" --arg pk "$priv_key" --arg s "$sni" \
       '.inbounds += [{"type":"vless","tag":"vless-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk}}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        open_port "$port" "tcp"; _save_node_meta "$port" "$node_name" "vless" "$pub_key"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip)
        echo -e "${G}✅ 成功！${R}"
        echo -e "${B}vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}${R}"
    else
        echo -e "${RED}配置校验失败${R}"; local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"; sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 Hysteria2 (修复: hop_ports 必须放在 tls 内部，否则sing-box直接报错回滚)
# ============================================================================
sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    command -v openssl >/dev/null 2>&1 || { echo -e "${RED}请先安装 openssl${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 Hysteria2 ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    local sni; sni=$(select_sni)

    local hop_ports="" hop_param=""
    echo -e "${Y}是否开启端口跳跃 (对抗QoS限速)?${R}"
    echo -e "${G}1. 不开启${R}"
    echo -e "${G}2. 开启${R}"
    read -e -p "选择 (回车默认不开): " hop_choice
    if [ "$hop_choice" = "2" ]; then
        read -e -p "输入跳跃端口范围 (如 20000-30000): " hop_input
        if [[ "$hop_input" =~ ^[0-9]{1,5}-[0-9]{1,5}$ ]]; then
            hop_ports="$hop_input"
            hop_param="&hop=${hop_input}"
            echo -e "${Y}⚠ 跳跃端口 ${hop_input} 的 UDP 必须在云安全组中放行！${R}"
        else
            echo -e "${RED}格式错误，已跳过端口跳跃${R}"
        fi
    fi

    echo -e "${Y}生成密码和证书...${R}"
    local pass; pass=$(openssl rand -base64 16)
    local crt="/etc/sing-box/hy2_${port}.crt" key="/etc/sing-box/hy2_${port}.key"
    [ ! -f "$crt" ] || [ ! -f "$key" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=${sni}" -days 3650 2>/dev/null
    chmod 600 "$key" 2>/dev/null; chmod 644 "$crt" 2>/dev/null

    local default_name="Hy2-${port}"; read -e -p "名称 (回车默认 ${default_name}): " node_name; [ -z "$node_name" ] && node_name="$default_name"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"

    # 核心修复：先写入标准结构，如果有跳跃端口再追加到 .tls 内部
    jq --argjson p "$port" --arg pass "$pass" --arg s "$sni" --arg crt "$crt" --arg key "$key" --arg hp "$hop_ports" \
       '.inbounds += [{"type":"hysteria2","tag":"hy2-in-\($p)","listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$s,"certificate_path":$crt,"key_path":$key}}] | if $hp != "" then .[-1].tls += {"hop_ports": $hp} else . end' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在放行防火墙...${R}"
        open_port "$port" "udp"
        if [ -n "$hop_ports" ]; then
            local iptables_hop; iptables_hop=$(echo "$hop_ports" | sed 's/-/:/')
            open_port "$iptables_hop" "udp"
        fi
        _save_node_meta "$port" "$node_name" "hysteria2" "" "$hop_ports"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"
            rm -f "$crt" "$key"; _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip)
        echo -e "${G}✅ 成功！${R}"
        echo -e "${B}hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}${hop_param}#${node_name}${R}"
        [ -n "$hop_ports" ] && echo -e "${H}注: 跳跃端口 ${hop_ports} 必须在云安全组放行 UDP${R}"
    else
        echo -e "${RED}配置校验失败${R}"; local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"
        rm -f "$crt" "$key"; sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 AnyTLS
# ============================================================================
sb_add_anytls() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 AnyTLS ---${R}"
    echo -e "${Y}⚠ 需自有域名+真实证书 (非Reality)${R}"
    read -e -p "域名 (已A记录解析到本机): " domain
    [ -z "$domain" ] && { echo -e "${RED}不能为空${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    domain=$(echo "$domain" | sed 's|^https\?://||' | sed 's|/.*||' | tr -d '[:space:]')
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    local default_name="AnyTLS-${port}"; read -e -p "名称 (回车默认 ${default_name}): " node_name; [ -z "$node_name" ] && node_name="$default_name"

    local cert_dir="/etc/sing-box/certs" cert_file="${cert_dir}/${domain}.fullchain.pem" key_file="${cert_dir}/${domain}.key.pem" cert_ok=0 is_self_signed=0
    if [ -f "$cert_file" ] && [ -f "$key_file" ] && openssl x509 -checkend 86400 -noout -in "$cert_file" 2>/dev/null; then
        local iss sub; iss=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null); sub=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null)
        [ "$iss" = "$sub" ] && is_self_signed=1; cert_ok=1; echo -e "${G}检测到现有证书${R}"
    fi
    if [ "$cert_ok" -eq 0 ]; then
        mkdir -p "$cert_dir"; local acme_sh=""
        [ -f "$HOME/.acme.sh/acme.sh" ] && acme_sh="$HOME/.acme.sh/acme.sh" || { [ -f "/root/.acme.sh/acme.sh" ] && acme_sh="/root/.acme.sh/acme.sh"; }
        [ -z "$acme_sh" ] && { curl -fsSL https://get.acme.sh | sh -s email="admin@${domain}" >/dev/null 2>&1; acme_sh="$HOME/.acme.sh/acme.sh"; }
        if [ -f "$acme_sh" ]; then
            echo -e "${Y}申请证书中 (需80端口)...${R}"; local p80=0
            ss -tlnp | grep -q ":80 " || { open_port 80 "tcp" >/dev/null 2>&1; p80=1; }
            "$acme_sh" --issue -d "$domain" --standalone --httpport 80 >/dev/null 2>&1 && \
            "$acme_sh" --install-cert -d "$domain" --fullchain-file "$cert_file" --key_file "$key_file" >/dev/null 2>&1 && \
            [ -f "$cert_file" ] && [ -s "$cert_file" ] && cert_ok=1
            [ "$p80" -eq 1 ] && open_port 80 "tcp" "close" >/dev/null 2>&1
        fi
        if [ "$cert_ok" -eq 0 ]; then
            echo -e "${Y}回退到自签证书...${R}"; openssl req -x509 -nodes -newkey ec:prime256v1 -keyout "$key_file" -out "$cert_file" -subj "/CN=${domain}" -days 3650 2>/dev/null
            [ -f "$cert_file" ] && [ -s "$cert_file" ] && { cert_ok=1; is_self_signed=1; }
        fi
    fi
    [ "$cert_ok" -eq 0 ] && { echo -e "${RED}证书失败${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    chmod 600 "$key_file" 2>/dev/null; chmod 644 "$cert_file" 2>/dev/null

    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg u "$uuid" --arg cert "$cert_file" --arg key "$key_file" \
       '.inbounds += [{"type":"anytls","tag":"anytls-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        open_port "$port" "tcp"; _save_node_meta "$port" "$node_name" "anytls"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"; _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip); local insecure=""; [ "$is_self_signed" -eq 1 ] && insecure="&insecure=1"
        echo -e "${G}✅ 成功！${R}"
        echo -e "${B}anytls://${uuid}@${my_ip}:${port}?sni=${domain}&type=tcp${insecure}#${node_name}${R}"
    else
        echo -e "${RED}校验失败${R}"; local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1); [ -n "$lb" ] && mv "$lb" "$conf"; sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 查看节点列表 (修复管道变量丢失问题)
# ============================================================================
_show_nodes_list() {
    local conf="/etc/sing-box/config.json" my_ip; my_ip=$(get_my_ip)
    local cnt; cnt=$(jq '.inbounds | length' "$conf" 2>/dev/null)
    if [ "${cnt:-0}" -eq 0 ] 2>/dev/null; then echo -e "${H}暂无节点${R}"; return 1; fi
    local meta; meta=$(cat "$META_FILE" 2>/dev/null || echo '{}')
    local idx=1
    # 关键修复：使用进程替换 < <(...) 替代管道 | ，解决 idx 在子shell中无法自增BUG
    while IFS= read -r in; do
        local type port node_name link
        type=$(echo "$in" | jq -r '.type')
        port=$(echo "$in" | jq -r '.listen_port')
        node_name=$(echo "$meta" | jq -r --arg p "$port" '.[$p].name // "未命名"')
        
        case "$type" in
            vless)
                local uuid sni pub_key flow flow_param=""
                uuid=$(echo "$in" | jq -r '.users[0].uuid')
                sni=$(echo "$in" | jq -r '.tls.server_name')
                flow=$(echo "$in" | jq -r '.users[0].flow // empty')
                pub_key=$(echo "$meta" | jq -r --arg p "$port" '.[$p].pub_key // ""')
                [ -n "$flow" ] && flow_param="&flow=${flow}"
                link="vless://${uuid}@${my_ip}:${port}?encryption=none${flow_param}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}"
                ;;
            anytls)
                local uuid sni cert_path insecure=""
                uuid=$(echo "$in" | jq -r '.users[0].uuid')
                cert_path=$(echo "$in" | jq -r '.tls.certificate_path')
                sni=$(echo "$cert_path" | xargs basename 2>/dev/null | sed 's/.fullchain.pem//')
                [ -z "$sni" ] && sni="domain"
                if [ -n "$cert_path" ] && [ -f "$cert_path" ]; then
                    local i s; i=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null); s=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null)
                    [ "$i" = "$s" ] && insecure="&insecure=1"
                fi
                link="anytls://${uuid}@${my_ip}:${port}?sni=${sni}&type=tcp${insecure}#${node_name}"
                ;;
            hysteria2)
                local pass sni hop_meta hop_param=""
                pass=$(echo "$in" | jq -r '.users[0].password')
                sni=$(echo "$in" | jq -r '.tls.server_name')
                hop_meta=$(echo "$meta" | jq -r --arg p "$port" '.[$p].hop_ports // empty')
                [ -n "$hop_meta" ] && hop_param="&hop=${hop_meta}"
                link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}${hop_param}#${node_name}"
                [ -n "$hop_meta" ] && node_name="${node_name} (跳跃:${hop_meta})"
                ;;
            *) link="${H}[不支持的协议类型: ${type}]${R}" ;;
        esac
        
        echo -e "${G}─────────────────────────────────────${R}"
        echo -e "${C}[${idx}]${R} ${Y}${node_name}${R}"
        echo -e "  协议: ${type} | 端口: ${port}"
        echo -e "  链接:"
        echo -e "  ${B}${link}${R}"
        idx=$((idx + 1))
    done < <(jq -c '.inbounds[]' "$conf" 2>/dev/null)
    echo -e "${G}─────────────────────────────────────${R}"
}
sb_view_nodes() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    clear
    echo -e "${G}========================================${R}"
    echo -e "       当前节点与链接              "
    echo -e "${G}========================================${R}"
    _show_nodes_list
    echo -e "${G}========================================${R}"
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 删除节点 (完美联动清理跳跃端口)
# ============================================================================
sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    sb_view_nodes
    local conf="/etc/sing-box/config.json"
    read -e -p "请输入要删除的节点端口号: " del_port
    
    if ! jq -e --argjson p "$del_port" '.inbounds[] | select(.listen_port == $p) | any' "$conf" >/dev/null 2>&1; then
        echo -e "${RED}未找到监听端口为 ${del_port} 的节点${R}"
        read -rs -n 1 -p "按任意键返回..."; return
    fi
    
    local node_type hop_del
    node_type=$(jq -r --argjson p "$del_port" '.inbounds[] | select(.listen_port == $p) | .type' "$conf")
    hop_del=$(jq -r --arg p "$del_port" '.[$p].hop_ports // empty' "$META_FILE" 2>/dev/null)

    cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$del_port" 'del(.inbounds[] | select(.listen_port == $p))' \
        "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在清理防火墙...${R}"
        if [ "$node_type" = "hysteria2" ]; then
            open_port "$del_port" "udp" "close"
            if [ -n "$hop_del" ]; then
                local iptables_hop; iptables_hop=$(echo "$hop_del" | sed 's/-/:/')
                open_port "$iptables_hop" "udp" "close"
            fi
        else
            open_port "$del_port" "tcp" "close"
        fi
        _del_node_meta "$del_port"
        systemctl restart sing-box
        echo -e "${G}✅ 节点删除成功！${R}"
    else
        echo -e "${RED}删除后配置校验失败，正在回滚...${R}"
        local lb; lb=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$lb" ]; then mv "$lb" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 内核菜单 & 主菜单 (彻底修复 echo -e 漏写导致不换行的问题)
# ============================================================================
Kernel_optimize() {
    root_use
    while true; do
        clear; local cur="未优化"
        [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        local mem_mb; mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
        echo -e "${gl_lv}内核调优 (直播特化)${gl_bai}"
        echo -e "当前: ${gl_huang}${cur:-未设置}${gl_bai} | 内存: ${gl_lv}${mem_mb}MB${gl_bai}"
        echo -e "--------------------"
        echo -e "1. 直播推流极限 (中转出口/高并发)"
        echo -e "2. 电竞游戏 (8MB防Bufferbloat)"
        echo -e "3. 直连推流 (落地机直接跑推流软件,无中转)"
        echo -e "--------------------"
        echo -e "4. 还原默认"
        echo -e "5. 验证状态"
        echo -e "--------------------"
        echo -e "0. 返回"
        echo -e "--------------------"
        read -e -p "选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; _kernel_optimize_core "直播推流极限" "stream" ;;
            2) cd ~; clear; _kernel_optimize_core "电竞游戏" "game" ;;
            3) cd ~; clear; _kernel_optimize_core "直连推流" "direct" ;;
            4) cd ~; clear; restore_defaults ;;
            5) verify_network_status; read -rs -n 1 -p "按任意键返回..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效${gl_bai}"; read -rs -n 1 -p "按任意键返回..." ;;
        esac
    done
}

main_menu() {
    root_use
    while true; do
        clear
        echo -e "${gl_kjlan}Linux YW 网络与节点管理${gl_bai}"
        echo -e "--------------------------------------------------"
        echo -e "  1. 内核调优 (直播/游戏/直连)"
        echo -e "  2. Sing-Box 节点管理"
        echo -e "  3. Swap 管理"
        echo -e "  4. BBRv3 内核"
        echo -e "  5. 系统信息"
        echo -e "--------------------------------------------------"
        echo -e "  6. 还原默认"
        echo -e "--------------------------------------------------"
        echo -e "  0. 退出"
        echo -e "--------------------------------------------------"
        read -e -p "选项: " main_choice
        case $main_choice in
            1) Kernel_optimize ;; 2) sb_manage_menu ;; 3) change_swap_size ;; 4) bbrv3 ;; 5) show_sys_info ;;
            6) restore_defaults ;; 0|"") echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;; *) sleep 1 ;;
        esac
    done
}

main_menu
