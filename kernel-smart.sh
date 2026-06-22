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
        if ! apt-get install -y "$@" >/tmp/yw_apt.log 2>&1; then
            echo -e "${gl_red}APT 安装失败，错误信息:${gl_bai}"
            tail -n 3 /tmp/yw_apt.log
            return 1
        fi
    elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y "$@" >/tmp/yw_yum.log 2>&1; then
            echo -e "${gl_red}YUM 安装失败，错误信息:${gl_bai}"
            tail -n 3 /tmp/yw_yum.log
            return 1
        fi
    fi
    return 0
}

server_reboot() {
    echo -e "${gl_lv}建议立即重启服务器以加载新内核...${gl_bai}"
    # 【修复】修复了原版 read -p 里面多了个冒号引号的语法笔误
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
        1) swap_size=1024 ;;
        2) swap_size=2048 ;;
        3) swap_size=4096 ;;
        4) swap_size=6144 ;;
        5)
            read -e -p "请输入自定义大小 (MB, 最小512): " swap_size
            if [ -z "$swap_size" ] || [ "$swap_size" -lt 512 ]; then
                echo -e "${gl_red}错误: 最小大小为512MB${gl_bai}"
                read -rs -n 1 -p "按任意键返回..."
                return 0
            fi
            ;;
        6)
            if [ "$current_swap" -gt 0 ]; then
                swapoff "$swap_file" 2>/dev/null
                rm -f "$swap_file"
                # 【安全修复】使用 sed -i 原地修改，绝对禁止 mv 覆盖 /etc/fstab 导致系统无法启动
                sed -i '/swapfile.*swap/d' /etc/fstab
                echo -e "${gl_lv}Swap 已移除${gl_bai}"
            else
                echo -e "${gl_huang}当前没有 Swap 文件${gl_bai}"
            fi
            read -rs -n 1 -p "按任意键返回..."
            return 0
            ;;
        0|"") return 0 ;;
        *) echo -e "${gl_red}无效选择${gl_bai}" ; read -rs -n 1 -p "按任意键返回..." ; return 0 ;;
    esac

    if [ -n "$swap_size" ]; then
        local needed_mb=$((swap_size + 100))
        local available_mb=$(df -m / | tail -1 | awk '{print $4}')
        
        if [ "$available_mb" -lt "$needed_mb" ]; then
            echo -e "${gl_red}磁盘空间不足，需要 ${needed_mb}MB${gl_bai}"
            read -rs -n 1 -p "按任意键返回..."
            return 0
        fi

        echo -e "${gl_lv}正在创建 Swap 文件 (${swap_size}MB)...${gl_bai}"
        swapoff "$swap_file" 2>/dev/null # 防止增加大小时冲突
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null
        chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1
        swapon "${swap_file}" >/dev/null 2>&1
        
        if ! grep -q "/swapfile none" /etc/fstab 2>/dev/null; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        
        echo -e "${gl_lv}✅ Swap 创建成功！当前大小: ${swap_size} MB${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# Core Optimization Logic (Network Expert Level)
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-high}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"

    echo -e "${gl_lv}正在应用${mode_name}参数..."

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG
    local PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN=16384

    # 【网络专家修复】提取共有变量，防止 web/balanced 模式下写入空值导致 sysctl 报错
    local TCP_NOTSENT_LOWAT=16384
    local TCP_FASTOPEN=3
    local TCP_TW_REUSE=1
    local TCP_MTU_PROBING=1
    local GAME_EXTRA=""
    local STREAM_EXTRA=""
    
    # 【网络专家新增】防抖动与防慢启动关键参数
    local TCP_SLOW_START_AFTER_IDLE=0
    local TCP_ECN=0 

    case "$scene" in
        high)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            ;;
        web)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=67108864; WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            # 【优化】Web(HTTP/2)不需要长 Keepalive 浪费 FD，120秒是最佳实践
            KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3 
            ;;
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            # 【优化】UDP缓冲给128KB是甜点位，避免无脑256KB导致小机器OOM
            UDP_RMEM_MIN=131072
            STREAM_EXTRA="
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072"
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072
            # 【核心优化】游戏包极小，大Buffer会引发Bufferbloat导致延迟飙升，降至16MB
            RMEM_MAX=16777216; WMEM_MAX=16777216 
            TCP_RMEM="4096 32768 16777216"; TCP_WMEM="4096 32768 16777216"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=5
            KEEPALIVE_TIME=60; KEEPALIVE_INTVL=10; KEEPALIVE_PROBES=3
            UDP_RMEM_MIN=131072
            GAME_EXTRA="
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072"
            ;;
        balanced)
            SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
            MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"
            SCHED_AUTOGROUP=1; THP="always"; NUMA=1; FIN_TIMEOUT=30
            KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
            TCP_SLOW_START_AFTER_IDLE=1 # 均衡模式关闭极端防慢启动
            ;;
        *)
            echo -e "${gl_red}错误: 未知场景 ${scene}${gl_bai}"; return 1 ;;
    esac

    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

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
    else
        MIN_FREE_KB=16384; SWAPPINESS=30; OVERCOMMIT=0
        RMEM_MAX=4194304; WMEM_MAX=4194304
        TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
        SOMAXCONN=1024; BACKLOG=1000
    fi

    local KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then CC="bbr"; QDISC="fq"; fi
    fi

    # 【逻辑修复】防止极小内存 VPS 算出 0 0 0 导致内核拒绝连接
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256))
    local TCP_MEM_DEF=$((MEM_MB_VAL * 512))
    local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384
    [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768

    # 【网络优化】动态计算连接池大小
    local TW_BUCKETS=$((SOMAXCONN * 4))
    local MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$TW_BUCKETS" -gt 262144 ] && TW_BUCKETS=262144
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    local backup_conf="${CONF}.bak.$(date +%s)"
    [ -f "$CONF" ] && cp "$CONF" "$backup_conf"

    local lock_file="/tmp/99-yw-optimize.lock"
    exec 200> "$lock_file"
    flock -x 200
    
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
 $GAME_EXTRA
 $STREAM_EXTRA
EOF

    flock -u 200
    exec 200>&-

    echo -e "${gl_lv}正在加载配置..."
    sysctl -p "$CONF" >/dev/null 2>&1
    
    local limits_added=0
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize" >> /etc/security/limits.conf
        echo -e "* soft nofile 1048576" >> /etc/security/limits.conf
        echo -e "* hard nofile 1048576" >> /etc/security/limits.conf
        echo -e "root soft nofile 1048576" >> /etc/security/limits.conf
        echo -e "root hard nofile 1048576" >> /etc/security/limits.conf
        limits_added=1
    fi
    
    if [ "$limits_added" -eq 1 ] || [ "$(ulimit -n)" -lt 1048576 ]; then
        ulimit -n 1048576 2>/dev/null
    fi

    check_swap
    bbr_on

    echo -e "${gl_lv}✅ 验证结果:${gl_bai}"
    echo -e "   - 拥塞控制: \e[32m$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)\e[0m"
    echo -e "   - 防抖动(ECN): \e[32m$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)\e[0m"
    echo -e "   - 慢启动重启: \e[32m$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)\e[0m"
    echo -e "   - Swap偏好: \e[32m$(sysctl -n vm.swappiness 2>/dev/null)\e[0m"
    echo -e "   - 文件描述符: \e[32m$(ulimit -n)\e[0m"
    echo -e "${gl_lv}✅ ${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
}

# ============================================================================
# BBRv3 (XanMod) Management
# ============================================================================

# 【代码重构】将嵌套函数全部提取到顶层，避免性能损耗和代码混乱
xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local key_url="https://dl.xanmod.org/archive.key"
    local fallback_key_url="${gh_proxy}raw.githubusercontent.com/YW/sh/main/archive.key"
    local os_codename=""

    if command -v lsb_release >/dev/null 2>&1; then
        os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then
        os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
    
    if ! echo "bookworm trixie forky sid noble plucky questing resolute faye gigi wilma xia zara zena" | grep -qw "$os_codename"; then
        os_codename="releases"
    fi
    
    if echo "jammy focal bullseye buster" | grep -qw "$os_codename" || [ "$os_codename" = "releases" ]; then
        echo -e "${gl_hong}XanMod 官方已停止对当前系统($os_codename)的 APT 源支持，请升级至 Debian12 / Ubuntu24 或更高版本。${gl_bai}"
        return 1
    fi

    [ -z "$os_codename" ] && { echo "无法获取系统代号"; return 1; }

    install wget gnupg ca-certificates || return 1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    
    local retry_count=0
    while [ $retry_count -lt 3 ]; do
        if wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; then break; fi
        echo "官方密钥下载失败，尝试备用源... ($retry_count)"
        if wget -qO - "$fallback_key_url" | gpg --dearmor -o "$keyring" --yes 2>/dev/null; then break; fi
        retry_count=$((retry_count + 1))
    done
    
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_psabi_level() {
    awk 'BEGIN {
        while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
        if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
        if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
        if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
        if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
        if (level > 0) { print level; exit }
        exit 1
    }' /proc/cpuinfo 2>/dev/null
}

xanmod_package_available() {
    apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^ ]'
}

xanmod_detect_package() {
    local psabi_level=$(xanmod_detect_psabi_level) || return 1
    [ -z "$psabi_level" ] && return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3

    apt update -y >/dev/null 2>&1

    for prefix in linux-xanmod linux-xanmod-lts; do
        local level="$psabi_level"
        while [ "$level" -ge 1 ]; do
            local package="${prefix}-x64v${level}"
            if xanmod_package_available "$package"; then
                [ "$level" != "$psabi_level" ] || [ "$prefix" = "linux-xanmod-lts" ] && echo "已自动匹配合适安装包: $package" >&2
                printf '%s\n' "$package"
                return 0
            fi
            level=$((level - 1))
        done
    done
    echo "软件源中未找到适配此CPU的XanMod内核包" >&2
    return 1
}

xanmod_installed() {
    dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'
}

xanmod_install_or_update() {
    local action="$1"
    check_disk_space 3 && check_swap || return 1
    xanmod_add_repo || { echo "XanMod仓库配置失败"; return 1; }

    local package=$(xanmod_detect_package) || { echo "找不到匹配内核包"; return 1; }
    apt update -y
    
    if [ "$action" = "update" ]; then
        apt install -y --only-upgrade "$package" || apt install -y "$package" || { echo "更新失败"; return 1; }
    else
        apt install -y "$package" || { echo "安装失败"; return 1; }
    fi

    bbr_on || { echo "BBR3写入失败"; return 1; }
    echo "XanMod BBRv3内核处理完成。重启后生效"
    server_reboot
}

xanmod_uninstall() {
    apt purge -y 'linux-*xanmod*'
    apt autoremove -y
    update-grub 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo "XanMod内核已卸载。重启后生效"
    server_reboot
}

bbrv3() {
    root_use
    send_stats "bbrv3管理"

    local cpu_arch=$(uname -m)
    if [ "$cpu_arch" = "aarch64" ]; then
        bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh)
        return 0
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo "当前环境不支持，仅支持Debian和Ubuntu系统"; return 0
        fi
    else
        echo "无法确定操作系统类型"; return 0
    fi

    if xanmod_installed; then
        while true; do
            clear
            echo "您已安装xanmod的BBRv3内核"
            echo "当前内核版本: $(uname -r)"
            echo "------------------------"
            echo "1. 更新BBRv3内核              2. 卸载BBRv3内核"
            echo "------------------------"
            echo "0. 返回上一级选单"
            read -e -p "请输入你的选择: " sub_choice
            case "$sub_choice" in
                1) xanmod_install_or_update update ;;
                2) xanmod_uninstall ;;
                *) break ;;
            esac
        done
    else
        clear
        echo "设置BBR3加速"
        echo "------------------------------------------------"
        echo "仅支持Debian/Ubuntu"
        echo "请备份数据，将为你升级Linux内核开启BBR3"
        echo "------------------------------------------------"
        read -e -p "确定继续吗？: " choice
        case "$choice" in
            [Yy]) xanmod_install_or_update install ;;
            *) echo "已取消" ;;
        esac
    fi
}

# ============================================================================
# Interactive Menu (General)
# ============================================================================

Kernel_optimize() {
    root_use
    while true; do
      clear
      send_stats "Linux内核调优管理"
      
      local current_mode="未优化"
      local conf_file="/etc/sysctl.d/99-yw-optimize.conf"
      if [ -f "$conf_file" ]; then
          local raw_mode=$(grep "^# 模式:" "$conf_file" 2>/dev/null | sed 's/^# 模式: //')
          [ -n "$raw_mode" ] && current_mode=$(echo "$raw_mode" | awk -F'|' '{print $1}' | xargs) || current_mode="系统优化已启用"
      fi

      echo -e "${gl_lv}Linux系统内核参数优化${gl_bai}"
      echo "------------------------------------------------"
      echo -e "当前模式: ${gl_huang}${current_mode}${gl_bai}"
      echo -e "提供多种系统参数调优模式，用户可以根据自身使用场景进行选择切换。"
      echo -e "${gl_huang}提示: ${gl_bai}生产环境请谨慎使用！"
      echo -e "--------------------"
      echo -e "1. 高性能优化模式：     最大化系统性能，激进的内存和网络参数。"
      echo -e "2. 均衡优化模式：       在性能与资源消耗之间取得平衡，适合日常使用。"
      echo -e "3. 网站优化模式：       针对网站服务器优化，超高并发连接队列。"
      echo -e "4. 直播优化模式：       针对直播推流优化，UDP 缓冲区加大，减少延迟。"
      echo -e "5. 游戏服优化模式：     针对游戏服务器优化，低延迟优先。"
      echo -e "6. BBRv3 内核安装      安装 XanMod BBRv3 内核 (仅Debian/Ubuntu)"
      echo -e "7. 还原默认设置：       将系统设置还原为默认配置。"
      echo -e "8. 自动调优：           根据测试数据自动调优内核参数。${gl_huang}★${gl_bai}"
      echo -e "9. 释放内存缓存：       强制清理系统 Cache (谨慎使用)"
      echo "--------------------"
      echo "0. 返回主菜单"
      echo "--------------------"
      read -e -p "请输入你的选择: " sub_choice
      
      case $sub_choice in
          1)
              cd ~; clear
              # 【逻辑修复】去掉 local，使子函数能正确继承变量
              tiaoyou_moshi="高性能优化模式"
              optimize_high_performance
              send_stats "高性能模式优化"
              ;;
          2)
              cd ~; clear
              tiaoyou_moshi="均衡优化模式"
              optimize_balanced
              send_stats "均衡模式优化"
              ;;
          3)
              cd ~; clear
              tiaoyou_moshi="网站优化模式"
              optimize_web_server
              send_stats "网站优化模式"
              ;;
          4)
              cd ~; clear
              tiaoyou_moshi="直播优化模式"
              _kernel_optimize_core "直播优化模式" "stream"
              send_stats "直播推流优化"
              ;;
          5)
              cd ~; clear
              tiaoyou_moshi="游戏服优化模式"
              _kernel_optimize_core "游戏服优化模式" "game"
              send_stats "游戏服优化"
              ;;
          6) cd ~; clear; bbrv3 ;;
          7)
              cd ~; clear
              restore_defaults
              curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh -o /tmp/network-optimize.sh && source /tmp/network-optimize.sh && restore_network_defaults
              send_stats "还原默认设置"
              ;;
          8)
              # 【UX优化】执行远程脚本前增加安全阻断提示
              echo -e "${gl_huang}即将拉取并执行远程网络优化脚本..."
              read -e -p "按回车键继续，或按 Ctrl+C 取消: "
              curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash
              send_stats "内核自动调优"
              ;;
          9)
              # 【UX优化】增加二次确认，防止生产环境误操作导致 IO 抖动
              echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动，生产环境请谨慎！${gl_bai}"
              read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice
              if [[ "$drop_choice" =~ ^[Yy]$ ]]; then
                  sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
                  echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"
              else
                  echo "已取消"
              fi
              read -rs -n 1 -p "按任意键继续..."
              ;;
          0|"") break ;;
          *) echo -e "${gl_red}无效的选择${gl_bai}" ; read -rs -n 1 -p "按任意键继续..." ;;
      esac
    done
}

# ============================================================================
# Public API Functions
# ============================================================================

optimize_high_performance() { _kernel_optimize_core "${tiaoyou_moshi:-高性能优化模式}" "high"; }
optimize_balanced() { _kernel_optimize_core "均衡优化模式" "balanced"; }
optimize_web_server() { _kernel_optimize_core "网站搭建优化模式" "web"; }

restore_network_defaults() {
    echo -e "${gl_lv}正在还原网络默认设置..."
    rm -f /etc/sysctl.d/99-network-optimize.conf
    sysctl --system 2>/dev/null | tail -1
    echo -e "${gl_lv}网络设置已还原${gl_bai}"
}

restore_defaults() {
    echo -e "${gl_lv}还原到默认设置...${gl_bai}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system 2>/dev/null | tail -1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    if grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf
    fi
    rm -f /etc/modules-load.d/bbr.conf 2>/dev/null
    echo -e "${gl_lv}系统已还原到默认设置${gl_bai}"
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

        # 【容错优化】增加超时，防止 ipinfo 卡死脚本
        local ipinfo=$(curl -s --connect-timeout 3 --max-time 5 ipinfo.io 2>/dev/null || echo "{}")
        local country=$(echo "$ipinfo" | awk -F'"' '/country/{print $4}')
        local city=$(echo "$ipinfo" | awk -F'"' '/city/{print $4}')
        local isp_info=$(echo "$ipinfo" | awk -F'"' '/org/{print $4}')

        local load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
        local dns_addresses=$(awk '/^nameserver/{printf "%s ", $2} END {print ""}' /etc/resolv.conf)
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
        local swap_info="${swap_used_mb}M/${swap_total_mb}M (${swap_percent})"

        local runtime=$(cat /proc/uptime 2>/dev/null | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')
        local timezone=$(cat /etc/timezone 2>/dev/null || echo "Unknown")
        local tcp_count=$(ss -t state established 2>/dev/null | wc -l)
        local udp_count=$(ss -u state established 2>/dev/null | wc -l)

        # 【逻辑优化】使用排除法统计流量，兼容所有非常规网卡
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
        
        # 【UX优化】信息查询里仅保留管理 Swap，删除了危险的释放缓存选项
        echo -e "${gl_huang}1. 管理虚拟内存"
        echo -e "0. 返回主菜单"
        echo -e "${gl_huang}=============="
        read -e -p "请输入选择: " menu_choice
        
        case "$menu_choice" in
            1) change_swap_size ;;
            0|"") break ;;
            *) break ;;
        esac
    done
    return 0
}

# ============================================================================
# Main Menu Entry Point
# ============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "${gl_huang}       YW 系统管理与优化脚本            ${gl_bai}"
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "${gl_lv}1. 系统信息查询"
        echo -e "${gl_huang}2. Linux 系统内核参数优化 (BBR/调优)"
        echo -e "${gl_hui}0. 退出程序"
        echo -e "${gl_huang}========================================${gl_bai}"
        read -e -p "请输入你的选择: " choice
        
        case "$choice" in
            1) show_sys_info ;;
            2) Kernel_optimize ;;
            0) echo -e "${gl_lv}感谢使用，再见！${gl_bai}"; break ;;
            *) echo -e "${gl_red}无效的选择，请重新输入${gl_bai}" ; sleep 1 ;;
        esac
    done
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
