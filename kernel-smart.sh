#!/usr/bin/env bash
# ============================================================================
# Linux YW内核与网络调优模块 (落地机全协议极速版 - 含 AnyTLS 修复版)
# ============================================================================

# --- 颜色定义 ---
gl_bai="\033[0m"
gl_lv="\033[32m"
gl_huang="\033[33m"
gl_hui="\033[90m"
gl_red="\033[31m"
gl_hong="\033[31m"
gl_kjlan="\033[32m"

R="$gl_bai"; G="$gl_lv"; Y="$gl_huang"; H="$gl_hui"; RED="$gl_red"; C="\033[36m"; B="\033[97m"

# --- 全局变量 ---
gh_proxy="https://"
tiaoyou_moshi="默认优化模式"

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
    if [ "$swap_total" -ge 512 ] 2>/dev/null || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
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
        echo -e "${gl_lv}检测到 zram 已在运行，跳过配置。${gl_bai}"
        return 0
    fi
    echo -e "${gl_lv}正在尝试自动配置 zram 替代 zswap...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then
            apt-get install -y zram-tools >/dev/null 2>&1 || return 1
        fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null
        sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1
        systemctl restart zramswap >/dev/null 2>&1
        if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then
            echo -e "${gl_lv}✅ zram 配置成功并已启动！${gl_bai}"
        else
            echo -e "${gl_huang}zram 启动失败。${gl_bai}"
        fi
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${gl_huang}CentOS/RHEL 建议手动执行: yum install zram-generator -y${gl_bai}"
    fi
}

check_disk_space() {
    local required_mb=$1
    local available_mb
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
            echo -e "${gl_red}APT 失败:${gl_bai}"
            tail -n 3 /tmp/yw_apt.log
            return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y "$@" >/tmp/yw_yum.log 2>/dev/null; then
            echo -e "${gl_red}YUM 失败:${gl_bai}"
            tail -n 3 /tmp/yw_yum.log
            return 1
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
# Core Kernel Optimization
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-high}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}正在应用${mode_name}参数...${gl_bai}"

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE
    local SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN=16384 TCP_NOTSENT_LOWAT=16384
    local TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1
    local TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0
    local HIGH_EXTRA="" WEB_EXTRA="" STREAM_EXTRA="" GAME_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA=""

    case "$scene" in
        high)
            SWAPPINESS=10; OVERCOMMIT=1; VFS_PRESSURE=50; DIRTY_RATIO=40; DIRTY_BG_RATIO=10
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            HIGH_EXTRA=$'vm.dirty_ratio = 40\nvm.dirty_background_ratio = 10'
            ;;
        web)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=15; KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3
            WEB_EXTRA=$'net.ipv4.tcp_max_tw_buckets = 524288\nnet.ipv4.tcp_max_syn_backlog = 16384'
            ;;
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=10; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=131072
            STREAM_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000'
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=8388608; WMEM_MAX=8388608
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=15; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=131072
            GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480'
            ;;
        gateway)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=32768; RMEM_MAX=8388608; WMEM_MAX=8388608
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=100000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0
            FIN_TIMEOUT=30; KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=16384
            GATEWAY_EXTRA=$'# ── 中转网关专属：保 CPU 算加密，不抢软中断 ──\nnet.core.optmem_max = 20480'
            ;;
        balanced)
            SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
            MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"
            SCHED_AUTOGROUP=0; THP="always"; NUMA=1
            FIN_TIMEOUT=30; KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
            TCP_SLOW_START_AFTER_IDLE=1
            BALANCED_EXTRA="vm.overcommit_memory = 0"
            ;;
        *)
            echo -e "${gl_red}错误: 未知场景${gl_bai}"
            return 1
            ;;
    esac

    # 内存自适应
    local MEM_MB_VAL
    MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP
    HAS_SWAP=$(free -m | awk '/Swap/{print $2}')

    if [ "$MEM_MB_VAL" -ge 16384 ] 2>/dev/null; then
        MIN_FREE_KB=131072
        [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 4096 ] 2>/dev/null; then
        MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ] 2>/dev/null; then
        MIN_FREE_KB=32768
        if [ "$scene" != "balanced" ] && [ "$scene" != "game" ] && [ "$scene" != "gateway" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
        fi
        if [ "$scene" = "game" ] || [ "$scene" = "gateway" ]; then
            RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
            GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072'
            GATEWAY_EXTRA=$'# ── 中转网关低内存自适应 ──'
        fi
    else
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10
        RMEM_MAX=4194304; WMEM_MAX=4194304
        SOMAXCONN=1024; BACKLOG=1000
        TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
        HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""
        GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""
        if [ -f /sys/module/zswap/parameters/enabled ]; then
            echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
        fi
        if [ "${HAS_SWAP:-0}" -gt 0 ] 2>/dev/null; then
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

    # BBR 检测
    local KVER
    KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            CC="bbr"; QDISC="fq"
        fi
    fi

    # TCP MEM 计算
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256))
    local TCP_MEM_DEF=$((MEM_MB_VAL * 512))
    local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384
    [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768

    if [ "$scene" = "stream" ] && [ "$MEM_MB_VAL" -ge 1024 ] 2>/dev/null; then
        STREAM_EXTRA="${STREAM_EXTRA}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    fi

    local TW_BUCKETS=$((SOMAXCONN * 4))
    local MAX_ORPHANS=$((SOMAXCONN * 2))
    if [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] 2>/dev/null; then
        TW_BUCKETS=524288
    fi
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    # 备份
    local backup_conf="${CONF}.bak.$(date +%s)"
    [ -f "$CONF" ] && cp "$CONF" "$backup_conf"

    # 写入配置
    cat > "$CONF" << SYSEOF
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
SYSEOF

    # conntrack
    if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        cat >> "$CONF" << SYSEOF
# ── 连接跟踪 ──
net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
SYSEOF
    else
        echo "# conntrack 未启用" >> "$CONF"
    fi

    # 场景附加参数
    [ -n "$HIGH_EXTRA" ] && echo -e "$HIGH_EXTRA" >> "$CONF"
    [ -n "$WEB_EXTRA" ] && echo -e "$WEB_EXTRA" >> "$CONF"
    [ -n "$STREAM_EXTRA" ] && echo -e "$STREAM_EXTRA" >> "$CONF"
    [ -n "$GAME_EXTRA" ] && echo -e "$GAME_EXTRA" >> "$CONF"
    [ -n "$BALANCED_EXTRA" ] && echo -e "$BALANCED_EXTRA" >> "$CONF"
    [ -n "$GATEWAY_EXTRA" ] && echo -e "$GATEWAY_EXTRA" >> "$CONF"

    echo -e "${gl_lv}正在加载配置...${gl_bai}"
    local sysctl_err
    sysctl_err=$(sysctl -p "$CONF" 2>&1 | grep -v "Invalid argument" | grep -v "No such file or directory" | grep -v "unknown key")
    if [ -n "$sysctl_err" ]; then
        echo -e "${gl_huang}Sysctl 加载时有以下异常(通常不影响核心功能):${gl_bai}"
        echo "$sysctl_err" | head -n 3
    fi

    # 文件描述符限制
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize" >> /etc/security/limits.conf
        echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf
    fi
    ulimit -n 1048576 2>/dev/null

    check_swap
    bbr_on

    echo -e "${gl_lv}✅ 验证结果:${gl_bai}"
    echo -e "   - 核心: \e[32m$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)\e[0m | 缓冲: \e[32m$((RMEM_MAX/1024/1024))MB\e[0m | Swap策略: \e[32m$SWAPPINESS\e[0m"
    echo -e "${gl_lv}✅ ${mode_name} 优化完成！${gl_bai}"
}

# ============================================================================
# 存根函数 (原脚本省略的模块)
# ============================================================================

restore_defaults() {
    echo -e "${Y}正在还原默认内核参数...${R}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then
        rm -f "$CONF"
        sysctl --system >/dev/null 2>&1
        echo -e "${G}✅ 已还原默认设置${R}"
    else
        echo -e "${H}无需还原，当前没有自定义优化配置${R}"
    fi
}

verify_network_status() {
    echo -e "${C}--- 当前网络内核参数状态 ---${R}"
    echo -e "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo -e "  队列调度: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo -e "  TCP FastOpen: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
    echo -e "  最大缓冲: $(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1024 / 1024 ))MB"
    echo -e "  SOMAXCONN: $(sysctl -n net.core.somaxconn 2>/dev/null)"
    echo -e "  SWAPPINESS: $(sysctl -n vm.swappiness 2>/dev/null)"
    echo -e "  BBR 状态: $(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -o bbr || echo '未启用')"
}

show_sys_info() {
    echo -e "${C}--- 系统信息 ---${R}"
    echo -e "  主机名: $(hostname)"
    echo -e "  内核: $(uname -r)"
    echo -e "  系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)"
    echo -e "  CPU: $(nproc) 核"
    echo -e "  内存: $(awk '/MemTotal/{printf "%.1fGB", $2/1024/1024}' /proc/meminfo)"
    echo -e "  Swap: $(free -m | awk '/Swap/{printf "%dMB", $2}')"
    echo -e "  磁盘: $(df -h / | tail -1 | awk '{print $4}') 可用"
    echo -e "  IP: $(get_my_ip)"
    echo -e "  运行时间: $(uptime -p 2>/dev/null || uptime)"
}

change_swap_size() {
    echo -e "${C}--- Swap 管理 ---${R}"
    local cur_swap
    cur_swap=$(free -m | awk '/Swap/{print $2}')
    echo -e "  当前 Swap: ${cur_swap}MB"
    echo -e "  1. 创建/扩大 Swap"
    echo -e "  2. 删除 Swap"
    echo -e "  0. 返回"
    read -e -p "选择: " sw_choice
    case "$sw_choice" in
        1)
            read -e -p "输入 Swap 大小: " sw_size
            [[ ! "$sw_size" =~ ^[0-9]+$ ]] && echo -e "${RED}无效数字${R}" && return
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
            dd if=/dev/zero of=/swapfile bs=1M count="$sw_size" 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            grep -q "/swapfile" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
            echo -e "${G}✅ Swap 设置为 ${sw_size}MB${R}"
            ;;
        2)
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
            sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
            echo -e "${G}✅ Swap 已删除${R}"
            ;;
    esac
}

bbrv3() {
    echo -e "${Y}BBRv3 内核管理 (仅限 Debian/Ubuntu)${R}"
    echo -e "${H}此功能需要联网下载内核，当前为存根实现${R}"
    echo -e "${H}如需使用，请参考原版脚本补全此模块${R}"
}

# ============================================================================
# Sing-Box 节点管理
# ============================================================================

get_my_ip() {
    local ip
    ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    echo "${ip:-未知IP}"
}

# ============================================================================
# SNI 优选 (精确测速版 - 每个域名测3轮取最小值)
# ============================================================================

test_tls_handshake() {
    local host="$1"
    local best=9999
    local i
    for i in 1 2 3; do
        local start end ms
        start=$(date +%s%N 2>/dev/null)
        if timeout 5 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
            end=$(date +%s%N 2>/dev/null)
            if [ -n "$start" ] && [ -n "$end" ] && [ "$end" -gt "$start" ] 2>/dev/null; then
                ms=$(( (end - start) / 1000000 ))
                [ "$ms" -ge 0 ] 2>/dev/null && [ "$ms" -lt "$best" ] && best=$ms
            fi
        fi
    done
    echo "$best"
}

select_sni() {
    echo -e "${Y}--- 伪装域名 (SNI) 设置 ---${R}" >&2
    echo -e "${G}1. 使用默认伪装域名${R}" >&2
    echo -e "${G}2. 自动优选最佳域名 (并发TLS握手测速，每域3轮取最小)${R}" >&2
    echo -e "${G}3. 手动输入域名${R}" >&2
    read -e -p "请选择 (1默认 / 2优选 / 3手动): " c
    case $c in
        1)
            echo "www.microsoft.com"
            ;;
        2)
            echo -e "${Y}[TLS 握手精确测速中，每域3轮取最小值，约需5-10秒]...${R}" >&2
            local d=(
                "azure.microsoft.com"
                "bing.com"
                "www.icloud.com"
                "statici.icloud.com"
                "www.microsoft.com"
                "xp.apple.com"
                "vs.aws.amazon.com"
                "www.xbox.com"
                "snap.licdn.com"
                "www.oracle.com"
                "www.xilinx.com"
                "ts2.tc.mm.bing.net"
                "images.nvidia.com"
                "www.lovelive-anime.jp"
                "speed.cloudflare.com"
                "workers.cloudflare.com"
            )
            local f="/tmp/sb_sni_test.$$"
            : > "$f"

            # 并发测试所有域名
            for i in "${d[@]}"; do
                (
                    t=$(test_tls_handshake "$i")
                    echo "${t} ${i}" >> "$f"
                ) &
            done
            wait

            # 找出延迟最低的
            local b_d="www.microsoft.com"
            local b_t=9999
            while IFS=' ' read -r t dom; do
                if [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null; then
                    b_t=$t
                    b_d="$dom"
                fi
            done < "$f"
            rm -f "$f"

            echo -e "${G}优选结果: ${b_d} (最低 ${b_t}ms)${R}" >&2
            echo "$b_d"
            ;;
        3)
            read -e -p "输入域名: " s
            echo "${s:-www.microsoft.com}"
            ;;
        *)
            echo "www.microsoft.com"
            ;;
    esac
}

# ============================================================================
# Sing-Box 基础检查与元数据管理
# ============================================================================

sb_check() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}请先安装 Sing-Box 核心！${R}"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}请先安装 jq (apt install jq -y)！${R}"
        return 1
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

META_FILE="/etc/sing-box/.nodes_meta"

_init_meta_file() {
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

# ============================================================================
# 防火墙端口管理
# ============================================================================

open_port() {
    local port=$1
    local proto="${2:-tcp}"
    local action="${3:-open}"
    local opened=0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        if [ "$action" = "open" ]; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        else
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [ "$action" = "open" ]; then
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        else
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
        fi
        firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then
        if [ "$action" = "open" ]; then
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                opened=1
            elif iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                opened=1
            fi
        else
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && opened=1
        fi
    fi

    if [ "$opened" -eq 1 ]; then
        if [ "$action" = "open" ]; then
            echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}"
        else
            echo -e "${Y}  ⚠ 已关闭 ${proto^^} ${port}${R}"
        fi
    else
        echo -e "${Y}  ⚠ 无法操作 ${proto^^} ${port}，请手动检查云安全组${R}"
    fi
}

# ============================================================================
# Sing-Box 管理主菜单
# ============================================================================

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
            if [ -f "$conf" ] && jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1; then
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
        echo -e "核心状态: ${sb_status}"
        echo -e "${G}========================================${R}"
        echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
        echo -e "${G}2.${R} 添加 VLESS Reality 节点 (优选SNI)"
        echo -e "${G}3.${R} 添加 Hysteria2 节点 (优选SNI)"
        echo -e "${C}4.${R} 添加 AnyTLS 节点 (需自有域名+证书)"
        echo -e "${H}5.${R} 查看节点与链接"
        echo -e "${RED}6.${R} 删除节点 (按端口)"
        echo -e "${H}7.${R} 重启/停止/查看日志"
        echo -e "${Y}8.${R} 手动开放端口 (防火墙放行)"
        echo -e "${G}========================================${R}"
        echo -e "${H}0.${R} 返回主菜单"
        echo -e "${G}========================================${R}"
        read -e -p "请输入选择: " c
        case $c in
            1)
                echo -e "${C}正在连接官方源安装...${R}"
                if command -v apt >/dev/null 2>&1; then
                    curl -fsSL https://sing-box.app/deb-install.sh | bash
                elif command -v yum >/dev/null 2>&1; then
                    curl -fsSL https://sing-box.app/rpm-install.sh | bash
                else
                    echo -e "${RED}不支持该系统${R}"
                fi
                read -rs -n 1 -p "按任意键继续..."
                ;;
            2) sb_add_reality ;;
            3) sb_add_hy2 ;;
            4) sb_add_anytls ;;
            5) sb_view_nodes ;;
            6) sb_del_node ;;
            7)
                echo -e "${C}1.重启 2.停止 3.日志 (回车取消):${R}"
                read -e -p "选择: " act
                case $act in
                    1) systemctl restart sing-box && echo -e "${G}已重启${R}" ;;
                    2) systemctl stop sing-box && echo -e "${Y}已停止${R}" ;;
                    3) journalctl -u sing-box -n 30 --no-pager ;;
                esac
                read -rs -n 1 -p "按任意键继续..."
                ;;
            8)
                echo -e "${C}--- 手动开放端口 ---${R}"
                read -e -p "请输入要放行的端口号: " m_port
                if [[ ! "$m_port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$m_port))" -lt 1 ] || [ "$((10#$m_port))" -gt 65535 ]; then
                    echo -e "${RED}端口无效，需为 1-65535 的数字${R}"
                else
                    echo -e "${Y}选择协议:${R}"
                    echo -e "${G}1.${R} TCP"
                    echo -e "${G}2.${R} UDP"
                    echo -e "${G}3.${R} TCP + UDP"
                    read -e -p "选择 (回车默认TCP): " m_proto
                    case "$m_proto" in
                        2) open_port "$m_port" "udp" ;;
                        3) open_port "$m_port" "tcp"; open_port "$m_port" "udp" ;;
                        *) open_port "$m_port" "tcp" ;;
                    esac
                fi
                read -rs -n 1 -p "按任意键继续..."
                ;;
            0|"") break ;;
            *) echo -e "${RED}输入无效${R}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 添加 VLESS Reality 节点
# ============================================================================

sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 VLESS Reality 落地节点 ---${R}"

    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    local sni
    sni=$(select_sni)

    echo -e "${Y}正在生成 UUID 和密钥对...${R}"
    local uuid priv_key pub_key keys
    uuid=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair 2>/dev/null)
    priv_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    pub_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')

    if [ -z "$pub_key" ] || [ -z "$priv_key" ]; then
        echo -e "${RED}密钥生成失败！请确认 sing-box 版本支持 Reality${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    local default_name="Reality-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"

    jq --argjson p "$port" \
       --arg u "$uuid" \
       --arg pk "$priv_key" \
       --arg s "$sni" \
       '.inbounds += [{"type":"vless","tag":"vless-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk}}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "tcp"
        _save_node_meta "$port" "$node_name" "vless" "$pub_key"

        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box

        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak
            latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then
                mv "$latest_bak" "$conf"
                echo -e "${Y}已从备份恢复原配置。${R}"
            fi
            _del_node_meta "$port"
            read -rs -n 1 -p "按任意键返回..."
            return
        fi

        local my_ip
        my_ip=$(get_my_ip)
        local link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}"

        echo -e "${G}✅ VLESS Reality 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak
        latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            mv "$latest_bak" "$conf"
            echo -e "${Y}已从备份恢复原配置。${R}"
        fi
        sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 Hysteria2 节点
# ============================================================================

sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}请先安装 openssl！${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    echo -e "${C}--- 添加 Hysteria2 落地节点 ---${R}"

    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    local sni
    sni=$(select_sni)

    echo -e "${Y}正在生成密码和自签证书...${R}"
    local pass
    pass=$(openssl rand -base64 16)
    local crt="/etc/sing-box/hy2_${port}.crt"
    local key="/etc/sing-box/hy2_${port}.key"

    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$key" -out "$crt" \
            -subj "/CN=${sni}" -days 3650 2>/dev/null
    fi
    chmod 600 "$key" 2>/dev/null
    chmod 644 "$crt" 2>/dev/null

    local default_name="Hy2-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"

    jq --argjson p "$port" \
       --arg pass "$pass" \
       --arg s "$sni" \
       --arg crt "$crt" \
       --arg key "$key" \
       '.inbounds += [{"type":"hysteria2","tag":"hy2-in-\($p)","listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$s,"certificate_path":$crt,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "udp"
        _save_node_meta "$port" "$node_name" "hysteria2"

        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box

        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak
            latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then
                mv "$latest_bak" "$conf"
                echo -e "${Y}已从备份恢复原配置。${R}"
            fi
            rm -f "$crt" "$key"
            _del_node_meta "$port"
            read -rs -n 1 -p "按任意键返回..."
            return
        fi

        local my_ip
        my_ip=$(get_my_ip)
        local link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#${node_name}"

        echo -e "${G}✅ Hysteria2 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
        echo -e "${H}注意: Hysteria2 是 UDP 协议，请确保云安全组也已放行 UDP ${port}${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak
        latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            mv "$latest_bak" "$conf"
            echo -e "${Y}已从备份恢复原配置。${R}"
        fi
        rm -f "$crt" "$key"
        sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 AnyTLS 节点 (完全重写 - 正确实现)
# ============================================================================
# AnyTLS 与 Reality 完全不同：
#   - Reality: 借用第三方域名 TLS 握手，不需要自己的证书
#   - AnyTLS: 需要自己的域名 + 真实 TLS 证书，TLS 握手外观与正常 HTTPS 完全一致
# ============================================================================

sb_add_anytls() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }

    echo -e "${C}--- 添加 AnyTLS 落地节点 ---${R}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo -e "${Y} ⚠  AnyTLS 协议要求 (与 Reality 不同)：${R}"
    echo -e "${Y}    1. 必须拥有一个已解析到本机的域名${R}"
    echo -e "${Y}    2. 必须获取该域名的真实 TLS 证书${R}"
    echo -e "${Y}    3. 不能借用第三方域名${R}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo ""

    # 步骤1: 输入域名
    read -e -p "请输入你的域名 (必须已 A 记录解析到本机IP): " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}域名不能为空${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi
    # 去掉可能的协议前缀
    domain=$(echo "$domain" | sed 's|^https\?://||' | sed 's|/.*||' | tr -d '[:space:]')

    # 步骤2: 验证域名解析
    local my_ip domain_ip
    my_ip=$(get_my_ip)
    domain_ip=$(curl -4 -s --connect-timeout 5 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null | jq -r '.Answer[0].data' 2>/dev/null)

    if [ -z "$domain_ip" ]; then
        domain_ip=$(dig +short "$domain" A 2>/dev/null | tail -1)
    fi

    echo -e "${H}  本机 IP: ${my_ip} | 域名解析: ${domain_ip:-未解析}${R}"

    if [ "$domain_ip" != "$my_ip" ] && [ -n "$domain_ip" ]; then
        echo -e "${RED}❌ 域名 ${domain} 未解析到本机 IP！${R}"
        echo -e "${Y}   AnyTLS 要求域名必须指向本机，否则无法申请证书${R}"
        read -e -p "   仍然继续？: " cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            read -rs -n 1 -p "按任意键返回..."
            return
        fi
    fi

    # 步骤3: 输入端口
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    # 步骤4: 生成 UUID
    echo -e "${Y}正在生成 UUID...${R}"
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)

    local default_name="AnyTLS-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    # 步骤5: 证书处理
    local cert_dir="/etc/sing-box/certs"
    local cert_file="${cert_dir}/${domain}.fullchain.pem"
    local key_file="${cert_dir}/${domain}.key.pem"
    local cert_ok=0
    local is_self_signed=0

    # 检查现有证书
    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        if openssl x509 -checkend 86400 -noout -in "$cert_file" 2>/dev/null; then
            # 检查是否自签
            local issuer subject
            issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
            subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null)
            if [ "$issuer" = "$subject" ]; then
                is_self_signed=1
                echo -e "${Y}检测到自签证书 (仍在有效期内)${R}"
            else
                echo -e "${G}检测到有效的 CA 签发证书，直接使用${R}"
            fi
            cert_ok=1
        else
            echo -e "${Y}现有证书已过期，需要重新申请${R}"
        fi
    fi

    if [ "$cert_ok" -eq 0 ]; then
        mkdir -p "$cert_dir"

        # 尝试 acme.sh 申请 Let's Encrypt 证书
        echo -e "${Y}正在尝试使用 acme.sh 申请 Let's Encrypt 证书...${R}"

        local acme_sh=""
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            acme_sh="$HOME/.acme.sh/acme.sh"
        elif [ -f "/root/.acme.sh/acme.sh" ]; then
            acme_sh="/root/.acme.sh/acme.sh"
        fi

        if [ -z "$acme_sh" ]; then
            echo -e "${Y}正在安装 acme.sh...${R}"
            curl -fsSL https://get.acme.sh | sh -s email="admin@${domain}" >/dev/null 2>&1
            acme_sh="$HOME/.acme.sh/acme.sh"
        fi

        if [ -f "$acme_sh" ]; then
            echo -e "${Y}尝试 standalone 模式 (需要 80 端口可用且域名已解析到本机)...${R}"

            # 临时放行 80 端口
            local port_80_opened=0
            if ! ss -tlnp | grep -q ":80 "; then
                open_port 80 "tcp" >/dev/null 2>&1
                port_80_opened=1
            fi

            "$acme_sh" --issue -d "$domain" --standalone --httpport 80 2>&1 | tail -3
            local acme_result=$?

            if [ "$acme_result" -eq 0 ]; then
                "$acme_sh" --install-cert -d "$domain" \
                    --fullchain-file "$cert_file" \
                    --key-file "$key_file" \
                    --reloadcmd "systemctl restart sing-box" 2>/dev/null

                if [ -f "$cert_file" ] && [ -f "$key_file" ] && [ -s "$cert_file" ]; then
                    echo -e "${G}✅ Let's Encrypt 证书申请成功！${R}"
                    cert_ok=1
                fi
            else
                echo -e "${Y}standalone 模式失败${R}"
            fi

            # 清理临时 80 端口放行
            if [ "$port_80_opened" -eq 1 ]; then
                open_port 80 "tcp" "close" >/dev/null 2>&1
            fi
        fi

        # acme.sh 失败，回退到自签证书
        if [ "$cert_ok" -eq 0 ]; then
            echo -e "${Y}Let's Encrypt 申请失败，回退到自签证书...${R}"
            echo -e "${H}⚠ 自签证书: AnyTLS 仍可工作，但 TLS 指纹可能被识别${R}"
            echo -e "${H}  如需完整伪装，请手动获取 CA 证书后重新添加节点${R}"

            openssl req -x509 -nodes -newkey ec:prime256v1 \
                -keyout "$key_file" -out "$cert_file" \
                -subj "/CN=${domain}" -days 3650 2>/dev/null

            if [ -f "$cert_file" ] && [ -f "$key_file" ] && [ -s "$cert_file" ]; then
                cert_ok=1
                is_self_signed=1
                echo -e "${Y}自签证书已生成${R}"
            fi
        fi
    fi

    if [ "$cert_ok" -eq 0 ]; then
        echo -e "${RED}❌ 证书准备失败，无法添加 AnyTLS 节点${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    chmod 600 "$key_file" 2>/dev/null
    chmod 644 "$cert_file" 2>/dev/null

    # 步骤6: 构建 sing-box 配置
    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"

    # AnyTLS 正确的 JSON 结构:
    # {
    #   "type": "anytls",
    #   "listen": "::",
    #   "listen_port": PORT,
    #   "users": [{"uuid": "xxx"}],
    #   "tls": {
    #     "enabled": true,
    #     "certificate_path": "/path/to/cert.pem",
    #     "key_path": "/path/to/key.pem"
    #   }
    # }
    jq --argjson p "$port" \
       --arg u "$uuid" \
       --arg cert "$cert_file" \
       --arg key "$key_file" \
       '.inbounds += [{"type":"anytls","tag":"anytls-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "tcp"
        _save_node_meta "$port" "$node_name" "anytls"

        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box

        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak
            latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then
                mv "$latest_bak" "$conf"
                echo -e "${Y}已从备份恢复原配置。${R}"
            fi
            _del_node_meta "$port"
            read -rs -n 1 -p "按任意键返回..."
            return
        fi

        local my_ip
        my_ip=$(get_my_ip)

        # AnyTLS 客户端链接格式
        local insecure_param=""
        if [ "$is_self_signed" -eq 1 ]; then
            insecure_param="&insecure=1"
        fi
        local link="anytls://${uuid}@${my_ip}:${port}?sni=${domain}&type=tcp${insecure_param}#${node_name}"

        echo -e "${G}✅ AnyTLS 节点添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
        echo ""
        echo -e "${H}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
        echo -e "${H} 注意事项:${R}"
        echo -e "${H}   - 客户端需使用 sing-box 1.11+ 内核${R}"
        echo -e "${H}   - 证书路径: ${cert_file}${R}"
        [ "$is_self_signed" -eq 1 ] && echo -e "${H}   - 当前使用自签证书，客户端需加 insecure=1${R}"
        [ "$is_self_signed" -eq 0 ] && echo -e "${H}   - 使用 CA 签发证书，伪装效果最佳${R}"
        echo -e "${H}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak
        latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            mv "$latest_bak" "$conf"
            echo -e "${Y}已从备份恢复原配置。${R}"
        fi
        echo -e "${RED}校验错误详情:${R}"
        sing-box check -c "$conf" 2>&1 | head -10
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 查看节点列表
# ============================================================================

_show_nodes_list() {
    local conf="/etc/sing-box/config.json"
    local my_ip
    my_ip=$(get_my_ip)

    local inbounds_count
    inbounds_count=$(jq '.inbounds | length' "$conf" 2>/dev/null)
    if [ "${inbounds_count:-0}" -eq 0 ] 2>/dev/null; then
        echo -e "${H}暂无节点${R}"
        return 1
    fi

    local meta_json
    meta_json=$(cat "$META_FILE" 2>/dev/null || echo '{}')
    local idx=1

    jq -c '.inbounds[]' "$conf" 2>/dev/null | while IFS= read -r in; do
        local type port node_name link

        type=$(echo "$in" | jq -r '.type')
        port=$(echo "$in" | jq -r '.listen_port')
        node_name=$(echo "$meta_json" | jq -r --arg p "$port" '.[$p].name // "未命名"')

        case "$type" in
            vless)
                local uuid sni pub_key flow
                uuid=$(echo "$in" | jq -r '.users[0].uuid')
                sni=$(echo "$in" | jq -r '.tls.server_name')
                flow=$(echo "$in" | jq -r '.users[0].flow // ""')
                pub_key=$(echo "$meta_json" | jq -r --arg p "$port" '.[$p].pub_key // ""')
                link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}"
                ;;
            anytls)
                local uuid sni
                uuid=$(echo "$in" | jq -r '.users[0].uuid')
                sni=$(echo "$in" | jq -r '.tls.certificate_path' | xargs basename 2>/dev/null | sed 's/.fullchain.pem//')
                [ -z "$sni" ] && sni="your-domain"
                # 检查是否自签
                local cert_path
                cert_path=$(echo "$in" | jq -r '.tls.certificate_path')
                local insecure_param=""
                if [ -n "$cert_path" ] && [ -f "$cert_path" ]; then
                    local issuer subject
                    issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null)
                    subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null)
                    [ "$issuer" = "$subject" ] && insecure_param="&insecure=1"
                fi
                link="anytls://${uuid}@${my_ip}:${port}?sni=${sni}&type=tcp${insecure_param}#${node_name}"
                ;;
            hysteria2)
                local pass sni
                pass=$(echo "$in" | jq -r '.users[0].password')
                sni=$(echo "$in" | jq -r '.tls.server_name')
                link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#${node_name}"
                ;;
            *)
                link="${H}[不支持的协议类型: ${type}]${R}"
                ;;
        esac

        echo -e "${G}─────────────────────────────────────${R}"
        echo -e "${C}[${idx}]${R} ${Y}${node_name}${R}"
        echo -e "  协议: ${type} | 端口: ${port}"
        echo -e "  链接:"
        echo -e "  ${B}${link}${R}"

        idx=$((idx + 1))
    done
    echo -e "${G}─────────────────────────────────────${R}"
}

sb_view_nodes() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    clear
    echo -e "${G}========================================${R}"
    echo -e "${G}       当前节点列表与链接              ${R}"
    echo -e "${G}========================================${R}"
    _show_nodes_list
    echo -e "${G}========================================${R}"
    read -rs -n 1 -p "按任意键返回菜单..."
}

# ============================================================================
# 删除节点
# ============================================================================

sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    sb_view_nodes

    local conf="/etc/sing-box/config.json"
    read -e -p "请输入要删除的节点端口号: " del_port

    if ! jq -e --argjson p "$del_port" '.inbounds[] | select(.listen_port == $p) | any' "$conf" >/dev/null 2>&1; then
        echo -e "${RED}未找到监听端口为 ${del_port} 的节点${R}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    local node_type
    node_type=$(jq -r --argjson p "$del_port" '.inbounds[] | select(.listen_port == $p) | .type' "$conf")

    cp "$conf" "${conf}.bak.$(date +%s)"

    jq --argjson p "$del_port" 'del(.inbounds[] | select(.listen_port == $p))' \
        "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在关闭防火墙端口...${R}"
        if [ "$node_type" = "hysteria2" ]; then
            open_port "$del_port" "udp" "close"
        else
            open_port "$del_port" "tcp" "close"
        fi
        _del_node_meta "$del_port"
        systemctl restart sing-box
        echo -e "${G}✅ 节点删除成功！${R}"
    else
        echo -e "${RED}删除后配置校验失败，正在回滚...${R}"
        local latest_bak
        latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            mv "$latest_bak" "$conf"
            echo -e "${Y}已从备份恢复原配置。${R}"
        fi
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 内核优化子菜单
# ============================================================================

_kernel_optimize_menu() {
    root_use
    while true; do
        clear
        local cur="未优化"
        if [ -f /etc/sysctl.d/99-yw-optimize.conf ]; then
            cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        fi
        echo -e "${gl_lv}Linux系统内核参数优化${gl_bai}"
        echo "------------------------------------------------"
        echo -e "当前模式: ${gl_huang}${cur:-系统优化已启用}${gl_bai}"
        echo -e "提供多种系统参数调优模式，用户可以根据自身使用场景进行选择切换。"
        echo -e "${gl_huang}提示: ${gl_bai}落地机强烈建议选 2. 均衡优化模式，最稳。"
        echo -e "--------------------"
        echo -e "1. 高性能优化模式：     极限IO聚簇写回，吞吐拉满"
        echo -e "2. 均衡优化模式：       稳定至上，内存安全锁  🌟落地机必选这个！"
        echo -e "3. 网站优化模式：       极限TW池，抗大促并发"
        echo -e "4. 直播优化模式：       UDP极限拉爆+网卡软中断狂暴 (落地机**绝对不要选这个！**)"
        echo -e "5. 游戏服优化模式：     8MB电竞级TCP防Bufferbloat"
        echo -e "6. 中转网关模式：       专精V2Ray/SS加密中转防卡顿"
        echo -e "7. 还原默认设置：       将系统设置还原为默认配置。"
        echo -e "8. 自动调优：           根据测试数据自动调优内核参数。"
        echo -e "9. 释放内存缓存：      强制清理系统 Cache (谨慎使用)"
        echo -e "10. 验证当前网络状态：  查看内核参数是否生效"
        echo -e "--------------------"
        echo "0. 返回主菜单"
        echo -e "--------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; tiaoyou_moshi="高性能优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "high" ;;
            2) cd ~; clear; _kernel_optimize_core "均衡优化模式" "balanced" ;;
            3) cd ~; clear; tiaoyou_moshi="网站优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "web" ;;
            4) cd ~; clear; tiaoyou_moshi="直播优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "stream" ;;
            5) cd ~; clear; tiaoyou_moshi="游戏服优化模式"; _kernel_optimize_core "$tiaoyou_moshi" "game" ;;
            6) cd ~; clear; tiaoyou_moshi="中转网关模式"; _kernel_optimize_core "$tiaoyou_moshi" "gateway" ;;
            7) cd ~; clear; restore_defaults ;;
            8)
                echo -e "${gl_huang}即将拉取并执行远程网络优化脚本...${gl_bai}"
                read -e -p "按回车键继续，或按 Ctrl+C 取消: "
                curl -sS "${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh" | bash
                ;;
            9)
                echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动，生产环境请谨慎！${gl_bai}"
                read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice
                if [[ "$drop_choice" =~ ^[Yy]$ ]]; then
                    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"
                else
                    echo "已取消"
                fi
                read -rs -n 1 -p "按任意键继续..."
                ;;
            10) verify_network_status; read -rs -n 1 -p "按任意键返回菜单..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效的选择${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
        esac
    done
}

# ============================================================================
# 主菜单
# ============================================================================

main_menu() {
    root_use
    while true; do
        clear
        echo -e "${gl_kjlan}Linux YW 网络与节点管理综合面板 (全协议极速版)${gl_bai}"
        echo "--------------------------------------------------"
        echo -e "  1. 系统内核参数优化 (落地机请选 2.均衡模式)"
        echo -e "  2. Sing-Box 节点管理 (含极速优选SNI)"
        echo -e "  3. Swap 虚拟内存管理"
        echo -e "  4. BBRv3 内核管理 (仅限Debian/Ubuntu)"
        echo -e "  5. 系统信息查询"
        echo "--------------------------------------------------"
        echo -e "  6. 还原默认设置"
        echo "--------------------------------------------------"
        echo -e "  0. 退出脚本"
        echo "--------------------------------------------------"
        read -e -p "请输入选项: " main_choice
        case $main_choice in
            1) _kernel_optimize_menu ;;
            2) sb_manage_menu ;;
            3) change_swap_size ;;
            4) bbrv3 ;;
            5) show_sys_info ;;
            6) restore_defaults ;;
            0|"") echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;;
            *) echo -e "${gl_red}无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 启动
# ============================================================================

main_menu
