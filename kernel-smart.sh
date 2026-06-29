#!/usr/bin/env bash
# ============================================================================
# Linux YW 内核与网络调优 (直播特化 + 游戏辅修 + 小内存/直连全场景覆盖)
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
            echo -e "${gl_huang}zram 服务启动失败，可能内核不支持。${gl_bai}"
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
    local current_swap
    current_swap=$(free -m | awk '/Swap/{print $2}')
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
            if [[ -z "$swap_size" || ! "$swap_size" =~ ^[0-9]+$ || "$swap_size" -lt 512 ]]; then
                echo -e "${gl_red}错误: 必须为纯数字且最小512MB${gl_bai}"
                read -rs -n 1 -p "按任意键返回..." && return 0
            fi
            ;;
        6)
            if [ "${current_swap:-0}" -gt 0 ]; then
                swapoff "$swap_file" 2>/dev/null
                rm -f "$swap_file"
                sed -i '/swapfile.*swap/d' /etc/fstab
                echo -e "${gl_lv}Swap 已移除${gl_bai}"
            else
                echo -e "${gl_huang}当前没有 Swap 文件${gl_bai}"
            fi
            read -rs -n 1 -p "按任意键返回..." && return 0
            ;;
        0|"") return 0 ;;
        *) echo -e "${gl_red}无效选择${gl_bai}"; read -rs -n 1 -p "按任意键返回..." && return 0 ;;
    esac
    if [ -n "$swap_size" ]; then
        local avail
        avail=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$avail" -lt $((swap_size + 100)) ]; then
            echo -e "${gl_red}磁盘空间不足${gl_bai}"
            read -rs -n 1 -p "按任意键返回..." && return 0
        fi
        echo -e "${gl_lv}正在创建 Swap 文件 (${swap_size}MB)...${gl_bai}"
        swapoff "$swap_file" 2>/dev/null
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null
        chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1
        swapon "${swap_file}" >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ Swap 创建成功！当前大小: ${swap_size} MB${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# Core Kernel Optimization
# 直播/游戏/直连 三场景，全内存段自适应
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-stream}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}正在应用${mode_name}参数...${gl_bai}"

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE
    local SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq"
    local UDP_RMEM_MIN UDP_WMEM_MIN UDP_RMEM_MAX UDP_WMEM_MAX
    local TCP_NOTSENT_LOWAT TCP_FASTOPEN TCP_TW_REUSE TCP_MTU_PROBING
    local TCP_SLOW_START_AFTER_IDLE TCP_ECN TCP_THIN_LINEAR_TIMEOUTS
    local TCP_NO_METRICS_SAVE TCP_FRTO
    local NETDEV_BUDGET NETDEV_MAX_BACKLOG
    local SCENE_EXTRA=""
    local MEMORY_TIER="" # 标记当前处于哪个内存段，用于日志

    # =============================================
    # 第一步：设定全量基准参数 (按场景)
    # =============================================
    case "$scene" in
        stream)
            SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072
            RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144
            UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0
            TCP_THIN_LINEAR_TIMEOUTS=1; TCP_NO_METRICS_SAVE=1; TCP_FRTO=0
            NETDEV_BUDGET=1200; NETDEV_MAX_BACKLOG=500000
            SCENE_EXTRA=$'net.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1'
            ;;
        game)
            SWAPPINESS=10; DIRTY_RATIO=10; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072
            RMEM_MAX=8388608; WMEM_MAX=8388608
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=120; KEEPALIVE_INTVL=15; KEEPALIVE_PROBES=3
            UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144
            UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0
            TCP_THIN_LINEAR_TIMEOUTS=1; TCP_NO_METRICS_SAVE=1; TCP_FRTO=0
            NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
            SCENE_EXTRA=$'net.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.core.optmem_max = 20480'
            ;;
        direct)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=65536
            RMEM_MAX=67108864; WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
            UDP_RMEM_MIN=16384; UDP_WMEM_MIN=16384
            UDP_RMEM_MAX=16777216; UDP_WMEM_MAX=16777216
            TCP_NOTSENT_LOWAT=16384; TCP_FASTOPEN=3; TCP_TW_REUSE=1; TCP_MTU_PROBING=1
            TCP_SLOW_START_AFTER_IDLE=0; TCP_ECN=0
            TCP_THIN_LINEAR_TIMEOUTS=0; TCP_NO_METRICS_SAVE=0; TCP_FRTO=1
            NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=100000
            SCENE_EXTRA=$'net.ipv4.tcp_frto = 1'
            ;;
        *)
            echo -e "${gl_red}错误: 未知场景${gl_bai}"
            return 1
            ;;
    esac

    # =============================================
    # 第二步：内存自适应 (逐级降级，保留场景特性)
    # =============================================
    local MEM_MB_VAL
    MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP
    HAS_SWAP=$(free -m | awk '/Swap/{print $2}')

    if [ "$MEM_MB_VAL" -ge 16384 ] 2>/dev/null; then
        # ── 大内存 (>=16GB): 全量参数，无需调整 ──
        MIN_FREE_KB=131072
        SWAPPINESS=5
        MEMORY_TIER="大内存全量"

    elif [ "$MEM_MB_VAL" -ge 4096 ] 2>/dev/null; then
        # ── 中等内存 (4-16GB): 轻微降低保留内存 ──
        MIN_FREE_KB=65536
        MEMORY_TIER="中等内存"

    elif [ "$MEM_MB_VAL" -ge 1024 ] 2>/dev/null; then
        # ── 小内存 (1-4GB): 缩缓冲区，但保留场景核心特性 ──
        MIN_FREE_KB=32768
        MEMORY_TIER="小内存自适应"

        case "$scene" in
            stream)
                # 直播：TCP 缓冲降到 16MB，但 UDP 必须保留拉满（直播命脉）
                RMEM_MAX=16777216; WMEM_MAX=16777216
                TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
                # netdev_budget 降到 600 防止 CPU 被软中断吃光
                NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
                # UDP 保持拉满
                UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144
                UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
                SCENE_EXTRA=$'# ── 直播小内存: TCP降缓冲保内存，UDP拉满保不丢包 ──\nnet.ipv4.udp_rmem_min = 262144\nnet.ipv4.udp_wmem_min = 262144\nnet.ipv4.udp_rmem_max = 268435456\nnet.ipv4.udp_wmem_max = 268435456\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 250000\nnet.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.udp_mem = 32768 65536 131072'
                ;;
            game)
                # 游戏：TCP 保持 8MB (游戏本来就小缓冲防 Bufferbloat)，UDP 拉满
                RMEM_MAX=8388608; WMEM_MAX=8388608
                TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
                NETDEV_BUDGET=600; NETDEV_MAX_BACKLOG=250000
                UDP_RMEM_MIN=262144; UDP_WMEM_MIN=262144
                UDP_RMEM_MAX=268435456; UDP_WMEM_MAX=268435456
                SCENE_EXTRA=$'# ── 游戏小内存: TCP 8MB防抖，UDP拉满保游戏包 ──\nnet.ipv4.udp_rmem_min = 262144\nnet.ipv4.udp_wmem_min = 262144\nnet.ipv4.udp_rmem_max = 268435456\nnet.ipv4.udp_wmem_max = 268435456\nnet.core.optmem_max = 20480\nnet.ipv4.tcp_thin_linear_timeouts = 1\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.ipv4.udp_mem = 32768 65536 131072'
                ;;
            direct)
                # 直连：TCP 缓冲降到 16MB，UDP 适度
                RMEM_MAX=16777216; WMEM_MAX=16777216
                TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
                UDP_RMEM_MIN=65536; UDP_WMEM_MIN=65536
                UDP_RMEM_MAX=8388608; UDP_WMEM_MAX=8388608
                SCENE_EXTRA=$'# ── 直连小内存 ──\nnet.ipv4.tcp_frto = 1'
                ;;
        esac

    else
        # ── 极小内存 (<1GB): 强制保命，但仍保留场景核心标识 ──
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10
        SOMAXCONN=2048; BACKLOG=2000; SYN_BACKLOG=2048
        MEMORY_TIER="极小内存保命"

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

        case "$scene" in
            stream)
                # TCP 降到 4MB，但 UDP 仍然给到 32MB (直播不能丢包)
                RMEM_MAX=4194304; WMEM_MAX=4194304
                TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
                UDP_RMEM_MIN=131072; UDP_WMEM_MIN=131072
                UDP_RMEM_MAX=33554432; UDP_WMEM_MAX=33554432
                NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=50000
                SCENE_EXTRA=$'# ── 直播极小内存: TCP极限压缩，UDP保32MB不丢包 ──\nnet.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 33554432\nnet.ipv4.udp_wmem_max = 33554432\nnet.core.netdev_budget = 300\nnet.core.netdev_max_backlog = 50000\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.udp_mem = 16384 32768 65536'
                ;;
            game)
                # TCP 保持 4MB (游戏本身就小缓冲)，UDP 给 32MB
                RMEM_MAX=4194304; WMEM_MAX=4194304
                TCP_RMEM="4096 16384 4194304"; TCP_WMEM="4096 16384 4194304"
                UDP_RMEM_MIN=131072; UDP_WMEM_MIN=131072
                UDP_RMEM_MAX=33554432; UDP_WMEM_MAX=33554432
                NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=50000
                SCENE_EXTRA=$'# ── 游戏极小内存: TCP 4MB防抖，UDP保32MB ──\nnet.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 33554432\nnet.ipv4.udp_wmem_max = 33554432\nnet.core.optmem_max = 10240\nnet.ipv4.tcp_no_metrics_save = 1\nnet.ipv4.tcp_frto = 0\nnet.ipv4.udp_mem = 16384 32768 65536'
                ;;
            direct)
                # 直连极小内存：全部压缩
                RMEM_MAX=4194304; WMEM_MAX=4194304
                TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
                UDP_RMEM_MIN=16384; UDP_WMEM_MIN=16384
                UDP_RMEM_MAX=4194304; UDP_WMEM_MAX=4194304
                NETDEV_BUDGET=300; NETDEV_MAX_BACKLOG=50000
                SCENE_EXTRA=$'# ── 直连极小内存 ──\nnet.ipv4.tcp_frto = 1'
                ;;
        esac
    fi

    # =============================================
    # 第三步：BBR 检测
    # =============================================
    local KVER
    KVER=$(uname -r | grep -oP '^\d+\.\d+')
    CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then
        modprobe tcp_bbr 2>/dev/null
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            CC="bbr"; QDISC="fq"
        fi
    fi

    # =============================================
    # 第四步：TCP MEM 计算
    # =============================================
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256))
    local TCP_MEM_DEF=$((MEM_MB_VAL * 512))
    local TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192
    [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384
    [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768

    local TW_BUCKETS=$((SOMAXCONN * 4))
    local MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072

    # =============================================
    # 第五步：写入配置
    # =============================================
    local backup_conf="${CONF}.bak.$(date +%s)"
    [ -f "$CONF" ] && cp "$CONF" "$backup_conf"

    cat > "$CONF" << SYSEOF
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene | 内存段: $MEMORY_TIER
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
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN:-16384}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN:-16384}

# ── 连接队列 ──
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $NETDEV_MAX_BACKLOG
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
net.ipv4.tcp_no_metrics_save = $TCP_NO_METRICS_SAVE
net.ipv4.tcp_frto = $TCP_FRTO

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
    if [ -n "$SCENE_EXTRA" ]; then
        echo "" >> "$CONF"
        echo -e "$SCENE_EXTRA" >> "$CONF"
    fi

    # =============================================
    # 第六步：加载并验证
    # =============================================
    echo -e "${gl_lv}正在加载配置...${gl_bai}"
    local sysctl_err
    sysctl_err=$(sysctl -p "$CONF" 2>&1 | grep -v "Invalid argument" | grep -v "No such file or directory" | grep -v "unknown key")
    if [ -n "$sysctl_err" ]; then
        echo -e "${gl_huang}Sysctl 加载时有以下异常(通常不影响核心功能):${gl_bai}"
        echo "$sysctl_err" | head -n 3
    fi

    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize" >> /etc/security/limits.conf
        echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf
    fi
    ulimit -n 1048576 2>/dev/null
    check_swap
    bbr_on

    echo -e "${gl_lv}✅ 验证结果:${gl_bai}"
    echo -e "   - 内存段: \e[33m${MEMORY_TIER} (${MEM_MB_VAL}MB)\e[0m"
    echo -e "   - 核心: \e[32m${CC}\e[0m | TCP缓冲: \e[32m$((RMEM_MAX/1024/1024))MB\e[0m | UDP最小: \e[32m$((UDP_RMEM_MIN/1024))KB\e[0m"
    echo -e "   - netdev_budget: \e[32m${NETDEV_BUDGET}\e[0m | Swap策略: \e[32m${SWAPPINESS}\e[0m"
    echo -e "${gl_lv}✅ ${mode_name} 优化完成！${gl_bai}"
}

# ============================================================================
# BBRv3 Management
# ============================================================================

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then
        os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then
        os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then
        os_codename="releases"
    fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then
        echo -e "${gl_hong}XanMod 已停止对当前系统($os_codename)支持${gl_bai}"; return 1
    fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    install wget gnupg ca-certificates || return 1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local psabi_level
    psabi_level=$(awk 'BEGIN{
        while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1;
        if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1;
        if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2;
        if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3;
        if(level>0){print level;exit}
    }' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] 2>/dev/null && psabi_level=3
    apt update -y >/dev/null 2>&1
    for prefix in linux-xanmod linux-xanmod-lts; do
        local l="$psabi_level"
        while [ "$l" -ge 1 ]; do
            local p="${prefix}-x64v${l}"
            if apt-cache policy "$p" 2>/dev/null | grep -q 'Candidate: [^ ]'; then
                printf '%s\n' "$p"; return 0
            fi
            l=$((l-1))
        done
    done
    return 1
}

bbrv3() {
    root_use
    if [ "$(uname -m)" = "aarch64" ]; then
        bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return 0
    fi
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo "仅支持Debian/Ubuntu"; return 0
        fi
    else
        return 0
    fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do
            clear; echo "当前: $(uname -r)"; echo "1.更新 2.卸载 0.返回"
            read -e -p "选择: " c
            case $c in
                1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade "$(xanmod_detect_package)" && bbr_on && server_reboot ;;
                2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;;
                *) break ;;
            esac
        done
    else
        clear; echo "设置BBR3 (仅Debian/Ubuntu)"
        read -e -p "继续？: " c
        if [[ "$c" =~ ^[Yy]$ ]]; then
            check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y "$(xanmod_detect_package)" && bbr_on && server_reboot
        fi
    fi
}

restore_defaults() {
    echo -e "${gl_lv}还原中...${gl_bai}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
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
    local rmem
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null)
    local udp_min
    udp_min=$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null)
    local budget
    budget=$(sysctl -n net.core.netdev_budget 2>/dev/null)
    local mode="未知"
    local mem_tier=""
    local mem_mb
    mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)

    if [ "$mem_mb" -lt 1024 ] 2>/dev/null; then
        mem_tier="极小内存(<1GB)"
    elif [ "$mem_mb" -lt 4096 ] 2>/dev/null; then
        mem_tier="小内存(1-4GB)"
    elif [ "$mem_mb" -lt 16384 ] 2>/dev/null; then
        mem_tier="中等内存(4-16GB)"
    else
        mem_tier="大内存(>=16GB)"
    fi

    case $rmem in
        4194304)
            if [ "$udp_min" -ge 131072 ] 2>/dev/null; then
                if [ "$budget" -ge 300 ] 2>/dev/null; then
                    mode="直播推流模式 (极小内存自适应, TCP 4MB + UDP ${udp_min}KB)"
                else
                    mode="直播推流模式 (小内存自适应, TCP 4MB + UDP ${udp_min}KB)"
                fi
            else
                mode="直连模式 (极小内存, TCP 4MB)"
            fi
            ;;
        8388608)
            if sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null | grep -q "120"; then
                mode="电竞游戏模式 (TCP 8MB 防Bufferbloat + 快速死连检测)"
            else
                mode="中转网关模式 (TCP 8MB)"
            fi
            ;;
        16777216)
            if [ "$udp_min" -ge 262144 ] 2>/dev/null; then
                mode="直播推流模式 (小内存自适应, TCP 16MB + UDP ${udp_min}KB 拉满)"
            else
                mode="直连模式 (小内存, TCP 16MB)"
            fi
            ;;
        67108864)
            mode="直连模式 (TCP 64MB, 均衡传输)"
            ;;
        134217728)
            if [ "$budget" -ge 1200 ] 2>/dev/null; then
                mode="直播推流极限模式 (TCP 64MB + UDP ${udp_min}KB + 软中断狂暴)"
            else
                mode="高性能模式 (TCP 64MB)"
            fi
            ;;
    esac

    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}       智能模式识别验证               ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "物理内存: ${mem_mb}MB (${mem_tier})"
    echo -e "算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | 队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo -e "防抖(ECN): $(sysctl -n net.ipv4.tcp_ecn 2>/dev/null) | 慢启动: $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
    echo -e "F-RTO: $(sysctl -n net.ipv4.tcp_frto 2>/dev/null) | 指标缓存: $(sysctl -n net.ipv4.tcp_no_metrics_save 2>/dev/null)"
    echo -e "最大TCP缓冲: $((rmem/1024/1024))MB"
    echo -e "UDP最小缓冲: $((udp_min/1024))KB"
    echo -e "netdev_budget: ${budget}"
    echo -e ">>> 智能鉴定结果: ${gl_lv}${mode}${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
}

# ============================================================================
# System Info
# ============================================================================

show_sys_info() {
    while true; do
        send_stats "系统信息查询"
        local cpu_info
        cpu_info=$(lscpu 2>/dev/null | awk -F':' '/Model name:/ {print $2}' | sed 's/^[ \t]*//')
        local cpu_usage_percent
        cpu_usage_percent=$(awk '{u=$2+$4; t=$2+$4+$5; if (NR==1){u1=u; t1=t;} else printf "%.0f\n", (($2+$4-u1) * 100 / (t-t1))}' <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))
        local cpu_cores
        cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
        local cpu_freq
        cpu_freq=$(grep "MHz" /proc/cpuinfo 2>/dev/null | head -n 1 | awk '{printf "%.1f GHz\n", $4/1000}')
        local mem_total_mb
        mem_total_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_avail_mb
        mem_avail_mb=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
        local mem_used_mb=$((mem_total_mb - mem_avail_mb))
        local mem_percent
        mem_percent=$(awk "BEGIN{printf \"%.1f\", ${mem_used_mb}*100/${mem_total_mb}}")
        local mem_info="${mem_avail_mb}M/${mem_total_mb}M (${mem_percent}%)"
        local disk_info
        disk_info=$(df -h / | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
        echo -ne "${gl_hui}正在获取外网IP信息(超时3秒自动跳过)...${gl_bai}\r"
        local ipinfo
        ipinfo=$(curl -s --connect-timeout 2 --max-time 3 ipinfo.io 2>/dev/null || echo "{}")
        local country
        country=$(echo "$ipinfo" | awk -F'"' '/country/{print $4}')
        local city
        city=$(echo "$ipinfo" | awk -F'"' '/city/{print $4}')
        local isp_info
        isp_info=$(echo "$ipinfo" | awk -F'"' '/org/{print $4}')
        local load
        load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
        local dns_addresses
        dns_addresses=$(awk '/^nameserver/{printf "%s ", $2 } END {print ""}' /etc/resolv.conf)
        local cpu_arch
        cpu_arch=$(uname -m)
        local hostname_val
        hostname_val=$(uname -n)
        local kernel_version
        kernel_version=$(uname -r)
        local congestion_algorithm
        congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        local queue_algorithm
        queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        local os_info
        os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')
        local current_time
        current_time=$(date "+%Y-%m-%d %I:%M %p")
        local swap_total_mb
        swap_total_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
        local swap_avail_mb
        swap_avail_mb=$(awk '/SwapFree/{printf "%d", $2/1024}' /proc/meminfo)
        local swap_used_mb=$((swap_total_mb - swap_avail_mb))
        local swap_percent="0%"
        [ "$swap_total_mb" -gt 0 ] 2>/dev/null && swap_percent=$(awk "BEGIN{printf \"%d%%\", ${swap_used_mb}*100/${swap_total_mb}}")
        local swap_info="${swap_used_mb}M/${swap_total_mb}M (${swap_percent}%)"
        local runtime
        runtime=$(cat /proc/uptime 2>/dev/null | awk -F. '{run_days=int($1 / 86400);run_hours=int(($1 % 86400) / 3600);run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}')
        local timezone
        timezone=$(cat /etc/timezone 2>/dev/null || echo "Unknown")
        local tcp_count
        tcp_count=$(ss -t state established 2>/dev/null | wc -l)
        local udp_count
        udp_count=$(ss -u state established 2>/dev/null | wc -l)
        local rx
        rx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$2} END{print a+0}' /proc/net/dev)
        local tx
        tx=$(awk 'NR>2 && $1 !~ /^lo:/ && $1 !~ /^sit/ {gsub(/:/,""); a+=$10} END{print a+0}' /proc/net/dev)
        local rx_gb
        rx_gb=$(awk "BEGIN{printf \"%.2f\", ${rx}/1024/1024/1024}")
        local tx_gb
        tx_gb=$(awk "BEGIN{printf \"%.2f\", ${tx}/1024/1024/1024}")
        local ipv4_addr
        ipv4_addr=$(ip -4 addr 2>/dev/null | grep inet | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
        local ipv6_addr
        ipv6_addr=$(ip -6 addr 2>/dev/null | grep inet6 | grep -v "::1" | awk '{print $2}' | head -1)
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
# SNI 优选 (串行精确测速 + 二轮筛选)
# ============================================================================

get_my_ip() {
    local ip
    ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    echo "${ip:-未知IP}"
}

_test_tls_once() {
    local host="$1"
    local t1 t2 ms
    t1=$(date +%s%3N 2>/dev/null)
    if timeout 2 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
        t2=$(date +%s%3N 2>/dev/null)
        ms=$((t2 - t1))
        if [ "$ms" -ge 0 ] 2>/dev/null; then echo "$ms"; else echo "9999"; fi
    else
        echo "9999"
    fi
}

select_sni() {
    echo -e "${Y}--- 伪装域名 (SNI) 设置 ---${R}" >&2
    echo -e "${G}1. 使用默认伪装域名${R}" >&2
    echo -e "${G}2. 自动优选最佳域名 (串行精确测速+二轮筛选)${R}" >&2
    echo -e "${G}3. 手动输入域名${R}" >&2
    read -e -p "请选择 (1默认 / 2优选 / 3手动): " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2)
            local d=(
                "azure.microsoft.com" "bing.com" "www.icloud.com"
                "statici.icloud.com" "www.microsoft.com" "xp.apple.com"
                "vs.aws.amazon.com" "www.xbox.com" "snap.licdn.com"
                "www.oracle.com" "www.xilinx.com" "ts2.tc.mm.bing.net"
                "images.nvidia.com" "speed.cloudflare.com" "workers.cloudflare.com"
                "www.lovelive-anime.jp"
            )
            local f="/tmp/sb_sni_test.$$"
            : > "$f"
            echo -e "${Y}[第1轮] 串行测速 16 个域名，约需 16-20 秒...${R}" >&2
            local idx=1
            for i in "${d[@]}"; do
                local ms
                ms=$(_test_tls_once "$i")
                echo "${ms} ${i}" >> "$f"
                if [ "$ms" -lt 9999 ] 2>/dev/null; then
                    echo -ne "  ${gl_hui}[${idx}/${#d[@]}]${R} ${i}: ${G}${ms}ms${R}\r" >&2
                else
                    echo -ne "  ${gl_hui}[${idx}/${#d[@]}]${R} ${i}: ${RED}超时${R}\r" >&2
                fi
                idx=$((idx + 1))
            done
            echo "" >&2
            local top5
            top5=$(sort -n "$f" | head -5)
            echo -e "${Y}[第2轮] 对前 5 名各测 3 轮取最小值...${R}" >&2
            local f2="/tmp/sb_sni_test2.$$"
            : > "$f2"
            while IFS=' ' read -r ms dom; do
                local best=9999
                local r
                for r in 1 2 3; do
                    local m
                    m=$(_test_tls_once "$dom")
                    if [ "$m" -lt "$best" ] 2>/dev/null; then best=$m; fi
                done
                echo "${best} ${dom}" >> "$f2"
                if [ "$best" -lt 9999 ] 2>/dev/null; then
                    echo -e "  ${dom}: ${G}${best}ms${R} (第1轮 ${ms}ms)" >&2
                else
                    echo -e "  ${dom}: ${RED}超时${R}" >&2
                fi
            done <<< "$top5"
            local b_d="www.microsoft.com"
            local b_t=9999
            while IFS=' ' read -r t dom; do
                if [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null; then b_t=$t; b_d="$dom"; fi
            done < "$f2"
            rm -f "$f" "$f2"
            echo "" >&2
            echo -e "${G}✅ 优选结果: ${b_d} (最低 ${b_t}ms)${R}" >&2
            echo "$b_d"
            ;;
        3)
            read -e -p "输入域名: " s
            echo "${s:-www.microsoft.com}"
            ;;
        *) echo "www.microsoft.com" ;;
    esac
}

# ============================================================================
# Sing-Box 基础
# ============================================================================

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

META_FILE="/etc/sing-box/.nodes_meta"

_init_meta_file() {
    if [ -f "/etc/sing-box/nodes_meta.json" ]; then rm -f "/etc/sing-box/nodes_meta.json"; fi
    if [ ! -f "$META_FILE" ] || ! jq -e . "$META_FILE" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"
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

# ============================================================================
# 防火墙
# ============================================================================

open_port() {
    local port=$1
    local proto="${2:-tcp}"
    local action="${3:-open}"
    local opened=0

    if [ "$action" = "open" ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1 && opened=1
        elif command -v iptables >/dev/null 2>&1; then
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                opened=1
            elif iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
                opened=1
            fi
        fi
        if [ "$opened" -eq 1 ]; then
            echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}"
        else
            echo -e "${Y}  ⚠ 无法自动放行 ${proto^^} ${port}，请手动检查云安全组${R}"
        fi
    else
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
            ufw delete allow "${port}/${proto}" >/dev/null 2>&1 && opened=1
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1 && opened=1
        elif command -v iptables >/dev/null 2>&1; then
            iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 && opened=1
        fi
        if [ "$opened" -eq 1 ]; then
            echo -e "${Y}  ⚠ 已关闭 ${proto^^} ${port}${R}"
        fi
    fi
}

# ============================================================================
# Sing-Box 管理菜单
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
        echo -e "核心状态: ${sb_status}"
        echo -e "${G}========================================${R}"
        echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
        echo -e "${G}2.${R} 添加 VLESS Reality 节点 (含优选SNI)"
        echo -e "${G}3.${R} 添加 Hysteria2 节点 (含优选SNI)"
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
                    echo -e "${G}1.${R} TCP"; echo -e "${G}2.${R} UDP"; echo -e "${G}3.${R} TCP + UDP"
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
# 添加 VLESS Reality
# ============================================================================

sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 VLESS Reality 落地节点 ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    local sni; sni=$(select_sni)
    echo -e "${Y}正在生成 UUID 和密钥对...${R}"
    local uuid priv_key pub_key keys
    uuid=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair 2>/dev/null)
    priv_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
    pub_key=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
    if [ -z "$pub_key" ] || [ -z "$priv_key" ]; then
        echo -e "${RED}密钥生成失败！请确认 sing-box 版本支持 Reality${R}"
        read -rs -n 1 -p "按任意键返回..."; return
    fi
    local default_name="Reality-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"
    sb_init_conf; local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg u "$uuid" --arg pk "$priv_key" --arg s "$sni" \
       '.inbounds += [{"type":"vless","tag":"vless-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk}}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "tcp"
        _save_node_meta "$port" "$node_name" "vless" "$pub_key"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip)
        local link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#${node_name}"
        echo -e "${G}✅ VLESS Reality 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"; echo -e "${B}${link}${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
        sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 Hysteria2
# ============================================================================

sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}请先安装 openssl！${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    echo -e "${C}--- 添加 Hysteria2 落地节点 ---${R}"
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    local sni; sni=$(select_sni)
    echo -e "${Y}正在生成密码和自签证书...${R}"
    local pass; pass=$(openssl rand -base64 16)
    local crt="/etc/sing-box/hy2_${port}.crt" key="/etc/sing-box/hy2_${port}.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=${sni}" -days 3650 2>/dev/null
    fi
    chmod 600 "$key" 2>/dev/null; chmod 644 "$crt" 2>/dev/null
    local default_name="Hy2-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"
    sb_init_conf; local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg pass "$pass" --arg s "$sni" --arg crt "$crt" --arg key "$key" \
       '.inbounds += [{"type":"hysteria2","tag":"hy2-in-\($p)","listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$s,"certificate_path":$crt,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "udp"
        _save_node_meta "$port" "$node_name" "hysteria2"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
            rm -f "$crt" "$key"; _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip)
        local link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#${node_name}"
        echo -e "${G}✅ Hysteria2 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"; echo -e "${B}${link}${R}"
        echo -e "${H}注意: Hysteria2 是 UDP 协议，请确保云安全组也已放行 UDP ${port}${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
        rm -f "$crt" "$key"; sing-box check -c "$conf" 2>&1 | head -5
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 添加 AnyTLS
# ============================================================================

sb_add_anytls() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 AnyTLS 落地节点 ---${R}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo -e "${Y} ⚠  AnyTLS 与 Reality 不同，要求：${R}"
    echo -e "${Y}    1. 必须拥有已解析到本机的域名${R}"
    echo -e "${Y}    2. 必须获取该域名的真实 TLS 证书${R}"
    echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo ""
    read -e -p "请输入你的域名 (必须已 A 记录解析到本机IP): " domain
    if [ -z "$domain" ]; then
        echo -e "${RED}域名不能为空${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    domain=$(echo "$domain" | sed 's|^https\?://||' | sed 's|/.*||' | tr -d '[:space:]')
    local my_ip domain_ip
    my_ip=$(get_my_ip)
    domain_ip=$(curl -4 -s --connect-timeout 5 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null | jq -r '.Answer[0].data' 2>/dev/null)
    if [ -z "$domain_ip" ]; then
        domain_ip=$(dig +short "$domain" A 2>/dev/null | tail -1)
    fi
    echo -e "${H}  本机 IP: ${my_ip} | 域名解析: ${domain_ip:-未解析}${R}"
    if [ -n "$domain_ip" ] && [ "$domain_ip" != "$my_ip" ]; then
        echo -e "${RED}❌ 域名 ${domain} 未解析到本机 IP！${R}"
        read -e -p "   仍然继续？: " cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then read -rs -n 1 -p "按任意键返回..."; return; fi
    fi
    read -e -p "端口: " port
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}端口错误 (需为 1-65535)${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    echo -e "${Y}正在生成 UUID...${R}"
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
    local default_name="AnyTLS-${port}"
    read -e -p "输入自定义名称 (回车跳过，默认: ${default_name}): " node_name
    [ -z "$node_name" ] && node_name="$default_name"

    local cert_dir="/etc/sing-box/certs"
    local cert_file="${cert_dir}/${domain}.fullchain.pem"
    local key_file="${cert_dir}/${domain}.key.pem"
    local cert_ok=0 is_self_signed=0

    if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        if openssl x509 -checkend 86400 -noout -in "$cert_file" 2>/dev/null; then
            local issuer subject
            issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
            subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null)
            if [ "$issuer" = "$subject" ]; then
                is_self_signed=1; echo -e "${Y}检测到自签证书 (仍在有效期内)${R}"
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
        local acme_sh=""
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then acme_sh="$HOME/.acme.sh/acme.sh"
        elif [ -f "/root/.acme.sh/acme.sh" ]; then acme_sh="/root/.acme.sh/acme.sh"; fi
        if [ -z "$acme_sh" ]; then
            echo -e "${Y}正在安装 acme.sh...${R}"
            curl -fsSL https://get.acme.sh | sh -s email="admin@${domain}" >/dev/null 2>&1
            acme_sh="$HOME/.acme.sh/acme.sh"
        fi
        if [ -f "$acme_sh" ]; then
            echo -e "${Y}尝试 standalone 模式申请 Let's Encrypt 证书 (需 80 端口可用)...${R}"
            local port_80_opened=0
            if ! ss -tlnp | grep -q ":80 "; then
                open_port 80 "tcp" >/dev/null 2>&1; port_80_opened=1
            fi
            "$acme_sh" --issue -d "$domain" --standalone --httpport 80 2>&1 | tail -3
            if [ $? -eq 0 ]; then
                "$acme_sh" --install-cert -d "$domain" \
                    --fullchain-file "$cert_file" --key-file "$key_file" \
                    --reloadcmd "systemctl restart sing-box" 2>/dev/null
                if [ -f "$cert_file" ] && [ -f "$key_file" ] && [ -s "$cert_file" ]; then
                    echo -e "${G}✅ Let's Encrypt 证书申请成功！${R}"; cert_ok=1
                fi
            else
                echo -e "${Y}standalone 模式失败${R}"
            fi
            if [ "$port_80_opened" -eq 1 ]; then open_port 80 "tcp" "close" >/dev/null 2>&1; fi
        fi
        if [ "$cert_ok" -eq 0 ]; then
            echo -e "${Y}Let's Encrypt 申请失败，回退到自签证书...${R}"
            echo -e "${H}⚠ 自签证书仍可工作，但 TLS 指纹可能被识别${R}"
            openssl req -x509 -nodes -newkey ec:prime256v1 \
                -keyout "$key_file" -out "$cert_file" \
                -subj "/CN=${domain}" -days 3650 2>/dev/null
            if [ -f "$cert_file" ] && [ -f "$key_file" ] && [ -s "$cert_file" ]; then
                cert_ok=1; is_self_signed=1; echo -e "${Y}自签证书已生成${R}"
            fi
        fi
    fi
    if [ "$cert_ok" -eq 0 ]; then
        echo -e "${RED}❌ 证书准备失败，无法添加 AnyTLS 节点${R}"
        read -rs -n 1 -p "按任意键返回..."; return
    fi
    chmod 600 "$key_file" 2>/dev/null; chmod 644 "$cert_file" 2>/dev/null

    sb_init_conf; local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg u "$uuid" --arg cert "$cert_file" --arg key "$key_file" \
       '.inbounds += [{"type":"anytls","tag":"anytls-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u}],"tls":{"enabled":true,"certificate_path":$cert,"key_path":$key}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在检查防火墙并放行端口...${R}"
        open_port "$port" "tcp"
        _save_node_meta "$port" "$node_name" "anytls"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"
            journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        local my_ip; my_ip=$(get_my_ip)
        local insecure_param=""
        [ "$is_self_signed" -eq 1 ] && insecure_param="&insecure=1"
        local link="anytls://${uuid}@${my_ip}:${port}?sni=${domain}&type=tcp${insecure_param}#${node_name}"
        echo -e "${G}✅ AnyTLS 节点添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"; echo -e "${B}${link}${R}"
        echo ""
        echo -e "${H}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
        echo -e "${H} 证书: ${cert_file}${R}"
        [ "$is_self_signed" -eq 1 ] && echo -e "${H} ⚠ 自签证书，客户端需加 insecure=1${R}"
        [ "$is_self_signed" -eq 0 ] && echo -e "${H} ✅ CA 签发证书，伪装效果最佳${R}"
        echo -e "${H}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    else
        echo -e "${RED}配置校验失败！已自动回滚到备份配置。${R}"
        local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
        echo -e "${RED}校验错误详情:${R}"; sing-box check -c "$conf" 2>&1 | head -10
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 查看节点列表
# ============================================================================

_show_nodes_list() {
    local conf="/etc/sing-box/config.json"
    local my_ip; my_ip=$(get_my_ip)
    local inbounds_count
    inbounds_count=$(jq '.inbounds | length' "$conf" 2>/dev/null)
    if [ "${inbounds_count:-0}" -eq 0 ] 2>/dev/null; then
        echo -e "${H}暂无节点${R}"; return 1
    fi
    local meta_json; meta_json=$(cat "$META_FILE" 2>/dev/null || echo '{}')
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
                local uuid sni cert_path insecure_param=""
                uuid=$(echo "$in" | jq -r '.users[0].uuid')
                cert_path=$(echo "$in" | jq -r '.tls.certificate_path')
                sni=$(echo "$cert_path" | xargs basename 2>/dev/null | sed 's/.fullchain.pem//')
                [ -z "$sni" ] && sni="your-domain"
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
            *) link="${H}[不支持的协议类型: ${type}]${R}" ;;
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
        read -rs -n 1 -p "按任意键返回..."; return
    fi
    local node_type
    node_type=$(jq -r --argjson p "$del_port" '.inbounds[] | select(.listen_port == $p) | .type' "$conf")
    cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$del_port" 'del(.inbounds[] | select(.listen_port == $p))' \
        "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}正在关闭防火墙端口...${R}"
        if [ "$node_type" = "hysteria2" ]; then open_port "$del_port" "udp" "close"
        else open_port "$del_port" "tcp" "close"; fi
        _del_node_meta "$del_port"
        systemctl restart sing-box
        echo -e "${G}✅ 节点删除成功！${R}"
    else
        echo -e "${RED}删除后配置校验失败，正在回滚...${R}"
        local latest_bak; latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then mv "$latest_bak" "$conf"; echo -e "${Y}已从备份恢复原配置。${R}"; fi
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 内核优化菜单 (直播 + 游戏 + 直连)
# ============================================================================

Kernel_optimize() {
    root_use
    while true; do
        clear
        local cur="未优化"
        if [ -f /etc/sysctl.d/99-yw-optimize.conf ]; then
            cur=$(grep "^# 模式:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# 模式: //' | awk -F'|' '{print $1}' | xargs)
        fi
        local mem_mb
        mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
        local mem_tag="${gl_lv}${mem_mb}MB${gl_bai}"
        if [ "$mem_mb" -lt 1024 ] 2>/dev/null; then
            mem_tag="${RED}${mem_mb}MB (极小)${gl_bai}"
        elif [ "$mem_mb" -lt 4096 ] 2>/dev/null; then
            mem_tag="${gl_huang}${mem_mb}MB (小)${gl_bai}"
        elif [ "$mem_mb" -lt 16384 ] 2>/dev/null; then
            mem_tag="${gl_lv}${mem_mb}MB (中)${gl_bai}"
        else
            mem_tag="${gl_lv}${mem_mb}MB (大)${gl_bai}"
        fi

        echo -e "${gl_lv}Linux系统内核参数优化 (直播特化版)${gl_bai}"
        echo "------------------------------------------------"
        echo -e "当前模式: ${gl_huang}${cur:-未设置}${gl_bai}  |  内存: ${mem_tag}"
        echo -e "--------------------"
        echo -e "1. 直播推流极限模式：   UDP 256KB缓冲+软中断狂暴+64MB TCP ${gl_huang}★推荐${gl_bai}"
        echo -e "2. 电竞游戏模式：       8MB防Bufferbloat+快速死连检测+UDP拉满"
        echo -e "3. 直连落地模式：       均衡TCP 64MB+开启F-RTO+适合直连出口"
        echo -e "--------------------"
        echo -e "4. 还原默认设置"
        echo -e "5. 释放内存缓存 (谨慎)"
        echo -e "6. 验证当前网络状态"
        echo "--------------------"
        echo "0. 返回主菜单"
        echo "--------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; _kernel_optimize_core "直播推流极限模式" "stream" ;;
            2) cd ~; clear; _kernel_optimize_core "电竞游戏模式" "game" ;;
            3) cd ~; clear; _kernel_optimize_core "直连落地模式" "direct" ;;
            4) cd ~; clear; restore_defaults ;;
            5)
                echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动！${gl_bai}"
                read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice
                if [[ "$drop_choice" =~ ^[Yy]$ ]]; then
                    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"
                else echo "已取消"; fi
                read -rs -n 1 -p "按任意键继续..."
                ;;
            6) verify_network_status; read -rs -n 1 -p "按任意键返回菜单..." ;;
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
        echo -e "${gl_kjlan}Linux YW 网络与节点管理 (直播特化版)${gl_bai}"
        echo "--------------------------------------------------"
        echo -e "  1. 内核调优 (直播 / 游戏 / 直连)"
        echo -e "  2. Sing-Box 节点管理 (含优选SNI)"
        echo -e "  3. Swap 虚拟内存管理"
        echo -e "  4. BBRv3 内核管理 (仅限Debian/Ubuntu)"
        echo -e "  5. 系统信息查询"
        echo "--------------------------------------------------"
        echo -e "  6. 还原所有默认设置"
        echo "--------------------------------------------------"
        echo -e "  0. 退出脚本"
        echo "--------------------------------------------------"
        read -e -p "请输入选项: " main_choice
        case $main_choice in
            1) Kernel_optimize ;;
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
