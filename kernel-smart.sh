#!/usr/bin/env bash
# ============================================================================
# Linux YW内核与网络调优模块 + Sing-Box节点管理 (终极修复版)
# 主场景: 直播推流 | 辅场景: 游戏服
# 特性: 自动内存检测防OOM + TCP/UDP全开 + 密钥生成容错
# ============================================================================

: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_hong:=\033[31m}"
: "${gl_kjlan:=\033[32m}"
: "${gh_proxy:=https://}"
: "${tiaoyou_moshi:=默认优化模式}"

send_stats() { :; return 0; }
root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${gl_red}错误：请使用 root 用户运行此脚本${gl_bai}"; exit 1; }; }

check_env() {
    local need_update=0
    if ! command -v curl >/dev/null 2>&1; then echo -e "${gl_huang}检测到未安装 curl，正在自动安装...${gl_bai}"; need_update=1; fi
    if ! command -v jq >/dev/null 2>&1; then echo -e "${gl_huang}检测到未安装 jq，正在自动安装...${gl_bai}"; need_update=1; fi
    if ! command -v openssl >/dev/null 2>&1; then echo -e "${gl_huang}检测到未安装 openssl，正在自动安装...${gl_bai}"; need_update=1; fi
    if [ "$need_update" -eq 1 ]; then
        if command -v apt >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            command -v curl >/dev/null 2>&1 || apt-get install -y curl >/dev/null 2>&1
            command -v jq >/dev/null 2>&1 || apt-get install -y jq >/dev/null 2>&1
            command -v openssl >/dev/null 2>&1 || apt-get install -y openssl >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            command -v curl >/dev/null 2>&1 || yum install -y curl >/dev/null 2>&1
            command -v jq >/dev/null 2>&1 || yum install -y jq >/dev/null 2>&1
            command -v openssl >/dev/null 2>&1 || yum install -y openssl >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            command -v curl >/dev/null 2>&1 || apk add curl >/dev/null 2>&1
            command -v jq >/dev/null 2>&1 || apk add jq >/dev/null 2>&1
            command -v openssl >/dev/null 2>&1 || apk add openssl >/dev/null 2>&1
        fi
        echo -e "${gl_lv}✅ 基础环境依赖准备完毕！${gl_bai}"
    fi
}

check_swap() {
    local swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -ge 512 ] || grep -q "/dev/zram" /proc/swaps 2>/dev/null; then return 0; fi
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
        echo -e "${gl_lv}检测到 zram 已在运行，跳过配置。${gl_bai}"; return 0
    fi
    echo -e "${gl_lv}正在尝试自动配置 zram 替代 zswap...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then apt-get install -y zram-tools >/dev/null 2>&1 || return 1; fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null
        sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1
        systemctl restart zramswap >/dev/null 2>&1
        grep -q "/dev/zram" /proc/swaps 2>/dev/null && echo -e "${gl_lv}✅ zram 配置成功并已启动！${gl_bai}" || echo -e "${gl_huang}zram 启动失败，可能内核不支持。${gl_bai}"
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${gl_huang}CentOS/RHEL 建议手动执行: yum install zram-generator -y${gl_bai}"
    fi
}

check_disk_space() {
    local required_mb=$1 available_mb
    available_mb=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$available_mb" -lt "$required_mb" ]; then
        echo -e "${gl_red}错误: 磁盘空间不足，需要 ${required_mb}MB，当前可用: ${gl_bai}${available_mb}MB"
        return 1
    fi
    return 0
}

install_pkg() {
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
            if [[ -z "$swap_size" || ! "$swap_size" =~ ^[0-9]+$ || "$swap_size" -lt 512 ]]; then
                echo -e "${gl_red}错误: 必须为纯数字且最小512MB${gl_bai}"
                read -rs -n 1 -p "按任意键返回..." && return 0
            fi
            ;;
        6)
            if [ "$current_swap" -gt 0 ]; then
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
        local avail=$(df -m / | tail -1 | awk '{print $4}')
        if [ "$avail" -lt $((swap_size + 100)) ]; then
            echo -e "${gl_red}磁盘空间不足${gl_bai}"
            read -rs -n 1 -p "按任意键返回..." && return 0
        fi
        echo -e "${gl_lv}正在创建 Swap 文件 (${swap_size}MB)...${gl_bai}"
        swapoff "$swap_file" 2>/dev/null
        dd if=/dev/zero of="${swap_file}" bs=1M count="${swap_size}" 2>/dev/null
        chmod 600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1
        swapon "${swap_file}" >/dev/null 2>/dev/null
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo -e "${gl_lv}✅ Swap 创建成功！当前大小: ${swap_size} MB${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 核心优化逻辑 (直播为主 + 游戏为辅 + 小内存防OOM特化版)
# ============================================================================
_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-stream_game}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}切换到${mode_name}...${gl_bai}"
    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE
    local SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN=131072
    local TCP_NOTSENT_LOWAT=16384 TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1
    local HIGH_EXTRA="" STREAM_EXTRA="" GAME_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA="" STREAM_GAME_EXTRA=""
    local TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0
    local CONNTRACK_MULT=32
    case "$scene" in
        stream_game)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=8; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=131072; RMEM_MAX=134217728; WMEM_MAX=134217728
            TCP_RMEM="4096 87380 67108864"; TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535; BACKLOG=500000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072
            STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000\nnet.core.optmem_max = 40960'
            ;;
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
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=131072
            GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480'
            ;;
        gateway)
            SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
            MIN_FREE_KB=32768; RMEM_MAX=8388608; WMEM_MAX=8388608
            TCP_RMEM="4096 16384 8388608"; TCP_WMEM="4096 16384 8388608"
            SOMAXCONN=65535; BACKLOG=100000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=30
            KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5; UDP_RMEM_MIN=16384
            GATEWAY_EXTRA=$'net.core.optmem_max = 20480'
            ;;
        balanced)
            SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
            MIN_FREE_KB=32768; RMEM_MAX=16777216; WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="32768 60999"
            SCHED_AUTOGROUP=0; THP="always"; NUMA=1; FIN_TIMEOUT=30
            KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
            TCP_SLOW_START_AFTER_IDLE=1
            BALANCED_EXTRA="vm.overcommit_memory = 0"
            ;;
        *)
            echo -e "${gl_red}错误: 未知场景${gl_bai}"; return 1 ;;
    esac
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    local HAS_SWAP=$(free -m | awk '/Swap/{print $2}')
    if [ "$MEM_MB_VAL" -ge 4096 ]; then
        MIN_FREE_KB=131072
        [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 2048 ]; then
        MIN_FREE_KB=65536
        RMEM_MAX=33554432; WMEM_MAX=33554432
        TCP_RMEM="4096 87380 33554432"; TCP_WMEM="4096 65536 33554432"
        BACKLOG=50000
        if [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ]; then
            STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 65536\nnet.ipv4.udp_wmem_min = 65536\nnet.ipv4.udp_rmem_max = 8388608\nnet.ipv4.udp_wmem_max = 8388608\nnet.core.netdev_budget = 800\nnet.core.netdev_max_backlog = 50000\nnet.core.optmem_max = 20480'
        fi
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then
        MIN_FREE_KB=32768
        RMEM_MAX=16777216; WMEM_MAX=16777216
        TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
        BACKLOG=10000
        if [ "$scene" = "stream_game" ] || [ "$scene" = "stream" ]; then
            STREAM_GAME_EXTRA=$'net.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.udp_rmem_max = 4194304\nnet.ipv4.udp_wmem_max = 4194304\nnet.core.netdev_budget = 600\nnet.core.netdev_max_backlog = 10000\nnet.core.optmem_max = 20480'
        fi
    else
        MIN_FREE_KB=16384; OVERCOMMIT=0; SWAPPINESS=10
        RMEM_MAX=4194304; WMEM_MAX=4194304; SOMAXCONN=1024; BACKLOG=1000
        TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
        HIGH_EXTRA=""; WEB_EXTRA=""; STREAM_EXTRA=""; GAME_EXTRA=""; BALANCED_EXTRA=""; GATEWAY_EXTRA=""; STREAM_GAME_EXTRA=""
        [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null
        if [ "$scene" = "game" ] || [ "$scene" = "gateway" ] || [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ]; then
            SOMAXCONN=512; BACKLOG=500; CONNTRACK_MULT=4; MIN_FREE_KB=16384
            echo -e "${gl_huang}检测极小内存(${MEM_MB_VAL}MB)，已启动极限保命模式(强制4MB缓冲)。${gl_bai}"
            if lsmod | grep -q nf_conntrack; then
                echo -e "${gl_red}⚠ 警告: nf_conntrack 模块已加载，将吃掉约10-15MB内存！${gl_bai}"
                echo -e "${gl_red}建议执行: rmmod nf_conntrack 以释放内存。${gl_bai}"
            fi
        fi
        if [ "$HAS_SWAP" -gt 0 ]; then
            SWAPPINESS=60
        else
            echo -e "${gl_red}检测极小内存(${MEM_MB_VAL}MB)无Swap！${gl_bai}"
            check_swap
        fi
        auto_setup_zram
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
    if [ "$scene" = "stream" ] || [ "$scene" = "stream_game" ]; then
        if [ "$MEM_MB_VAL" -ge 1024 ]; then
            STREAM_GAME_EXTRA="${STREAM_GAME_EXTRA:-${STREAM_EXTRA}}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
        fi
    fi
    local TW_BUCKETS=$((SOMAXCONN * 4))
    local MAX_ORPHANS=$((SOMAXCONN * 2))
    [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288
    [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288
    [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    local backup_conf="${CONF}.bak.$(date +%s)"
    [ -f "$CONF" ] && cp "$CONF" "$backup_conf"
    local lock_file="/tmp/99-yw-optimize.lock"
    exec 200> "$lock_file"; flock -x 200
    echo -e "${gl_lv}写入优化配置...${gl_bai}"
    cat > "$CONF" << EOF
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB_VAL}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
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
 $( if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * CONNTRACK_MAX))"; echo "net.netfilter.nf_conntrack_tcp_timeout_established = 1800"; echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15"; echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10"; echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 10"; else echo "# conntrack 未启用"; fi )
 $HIGH_EXTRA
 $WEB_EXTRA
 $STREAM_EXTRA
 $GAME_EXTRA
 $BALANCED_EXTRA
 $GATEWAY_EXTRA
 $STREAM_GAME_EXTRA
EOF
    flock -u 200; exec 200>&-
    echo -e "${gl_lv}应用优化参数...${gl_bai}"
    local total_params error_params sysctl_output applied_params
    total_params=$(grep -cE '^[a-z]' "$CONF" 2>/dev/null) || total_params=0
    sysctl_output=$(sysctl -p "$CONF" 2>&1)
    error_params=$(echo "$sysctl_output" | grep -cE "Invalid argument|No such file or directory|unknown key" 2>/dev/null) || error_params=0
    applied_params=$((total_params - error_params))
    echo -e "${gl_lv}已应用 ${applied_params} 项参数，跳过 ${error_params} 项不支持的参数${gl_bai}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        echo -e "\n# YW-optimize" >> /etc/security/limits.conf
        echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf
    fi
    ulimit -n 1048576 2>/dev/null
    check_swap >/dev/null 2>&1
    bbr_on
    echo -e "${gl_lv}${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
    echo -e "${gl_lv}内存: ${MEM_MB_VAL}MB | 拥塞算法: ${CC} | 队列: ${QDISC}${gl_bai}"
    echo ""
    read -rs -n 1 -p "按任意键继续..."
    echo ""
}

xanmod_add_repo() {
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local os_codename=""
    if command -v lsb_release >/dev/null 2>&1; then os_codename=$(lsb_release -sc)
    elif [ -r /etc/os-release ]; then os_codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); fi
    if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$os_codename"; then os_codename="releases"; fi
    if echo "jammy focal bullseye buster releases" | grep -qw "$os_codename"; then
        echo -e "${gl_hong}XanMod 已停止对当前系统($os_codename)支持${gl_bai}"; return 1
    fi
    [ -z "$os_codename" ] && { echo "无法获取代号"; return 1; }
    install_pkg wget gnupg ca-certificates || return 1
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
    wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$keyring" --yes 2>/dev/null
    chmod 644 "$keyring"
    echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
}

xanmod_detect_package() {
    local psabi_level=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level=1; if(level==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level=2; if(level==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level=3; if(level>0){print level;exit}}' /proc/cpuinfo 2>/dev/null) || return 1
    [ "$psabi_level" -gt 3 ] && psabi_level=3
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
    if [ "$(uname -m)" = "aarch64" ]; then bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return 0; fi
    if [ -r /etc/os-release ]; then
        . /etc/os_release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then echo "仅支持Debian/Ubuntu"; return 0; fi
    else return 0; fi
    if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
        while true; do
            clear
            echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"
            read -e -p "选择: " c
            case $c in
                1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;;
                2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;;
                *) break ;;
            esac
        done
    else
        clear
        echo "设置BBR3 (仅Debian/Ubuntu)"
        read -e -p "继续？: " c
        [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot
    fi
}

restore_defaults() {
    echo -e "${gl_lv}还原中...${gl_bai}"
    rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null
    if [ -f /sys/module/zswap/parameters/enabled ]; then echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; fi
    sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled zramswap >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到由脚本部署的 zram，正在停止并取消开机自启...${gl_bai}"
        systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1
    fi
    echo -e "${gl_lv}已还原所有设置（包括禁用 zram）${gl_bai}"
    read -rs -n 1 -p "按任意键继续..."
    echo ""
}

verify_network_status() {
    clear
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null) mode="未知"
    case $rmem in
        8388608)
            if sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null | grep -q "300"; then mode="中转网关模式 (8MB 防止卡顿+保隧道)"
            else mode="电竞级游戏模式 (8MB 绝杀缓冲)"; fi ;;
        16777216) mode="通用游戏/中等内存 (16MB)" ;;
        33554432) mode="2GB-4GB折中直播模式 (32MB)" ;;
        4194304) mode="极限低内存保护 (4MB)" ;;
        67108864|134217728)
            if sysctl -n net.core.netdev_budget 2>/dev/null | grep -q "1200"; then
                if sysctl -n net.core.optmem_max 2>/dev/null | grep -q "40960"; then mode="直播+游戏混合模式 (64MB UDP狂暴+optmem加大) ★"
                else mode="直播推流模式 (64MB + 软中断加速)"; fi
            elif sysctl -n vm.dirty_ratio 2>/dev/null | grep -q "40"; then mode="高性能下载模式 (64MB + IO聚簇)"
            else mode="高并发网站模式 (64MB + 极限TW池)"; fi ;;
    esac
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}       智能模式识别验证${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "算法: $(sysctl -n net.ipv4.tcp_congestion_control) | 队列: $(sysctl -n net.core.default_qdisc)"
    echo -e "防抖(ECN): $(sysctl -n net.ipv4.tcp_ecn) | 慢启动: $(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
    echo -e "最大TCP缓冲: $((rmem/1024/1024))MB"
    echo -e "UDP最小缓冲: $(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || echo N/A)"
    echo -e "网卡软中断预算: $(sysctl -n net.core.netdev_budget 2>/dev/null || echo N/A)"
    echo -e "optmem_max: $(sysctl -n net.core.optmem_max 2>/dev/null || echo N/A)"
    echo -e ">>> 智能鉴定结果: ${gl_lv}${mode}${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
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
        echo -e "${gl_hong}★ 1. 直播+游戏混合模式：  UDP狂暴+低延迟TCP (推荐)${gl_bai}"
        echo -e "2. 高性能优化模式：       极限IO聚簇写回，吞吐拉满"
        echo -e "3. 均衡优化模式：         稳定至上，内存安全锁"
        echo -e "4. 网站优化模式：         极限TW池，抗大促并发"
        echo -e "5. 纯直播优化模式：       UDP极限拉爆+网卡软中断狂暴"
        echo -e "6. 纯游戏服优化模式：     8MB电竞级TCP防Bufferbloat"
        echo -e "7. 中转网关模式：         专精V2Ray/SS加密中转防卡顿"
        echo -e "--------------------"
        echo -e "8. 还原默认设置"
        echo -e "9. 自动调优 (远程脚本)"
        echo -e "10. 释放内存缓存"
        echo -e "11. 验证当前网络状态 ${gl_huang}★${gl_bai}"
        echo "--------------------"
        echo "0. 返回主菜单"
        echo "--------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) cd ~; clear; _kernel_optimize_core "直播+游戏混合模式" "stream_game" ;;
            2) cd ~; clear; _kernel_optimize_core "高性能优化模式" "high" ;;
            3) cd ~; clear; _kernel_optimize_core "均衡优化模式" "balanced" ;;
            4) cd ~; clear; _kernel_optimize_core "网站优化模式" "web" ;;
            5) cd ~; clear; _kernel_optimize_core "直播优化模式" "stream" ;;
            6) cd ~; clear; _kernel_optimize_core "游戏服优化模式" "game" ;;
            7) cd ~; clear; _kernel_optimize_core "中转网关模式" "gateway" ;;
            8) cd ~; clear; restore_defaults ;;
            9) echo -e "${gl_huang}即将拉取并执行远程网络优化脚本..."; read -e -p "按回车键继续，或按 Ctrl+C 取消: "; curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;;
            10) echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动，生产环境请谨慎！${gl_bai}"; read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice; if [[ "$drop_choice" =~ ^[Yy]$ ]]; then sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"; else echo "已取消"; fi; read -rs -n 1 -p "按任意键继续..." ;;
            11) verify_network_status; read -rs -n 1 -p "按任意键返回菜单..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效的选择${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
        esac
    done
}
# ============================================================================
# 模块 5：落地机节点管理面板 (修复版)
# ============================================================================
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="\033[36m"

get_my_ip() {
    local ip
    ip=$(curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null \
      || curl -4 -s -f --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    echo "${ip:-未知IP}"
}

url_encode() {
    local str="$1"
    printf '%s' "$str" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/@/%40/g'
}

_test_tls_once() {
    local host="$1" t1 t2 ms
    t1=$(date +%s%3N 2>/dev/null)
    if timeout 2 openssl s_client -connect "${host}:443" -servername "${host}" </dev/null &>/dev/null; then
        t2=$(date +%s%3N 2>/dev/null)
        ms=$((t2 - t1))
        if [ "$ms" -ge 0 ] 2>/dev/null; then echo "$ms"; else echo "9999"; fi
    else echo "9999"
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
            local d=("azure.microsoft.com" "bing.com" "www.icloud.com" "statici.icloud.com" "www.microsoft.com" "xp.apple.com" "vs.aws.amazon.com" "www.xbox.com" "snap.licdn.com" "www.oracle.com" "www.xilinx.com" "ts2.tc.mm.bing.net" "images.nvidia.com" "speed.cloudflare.com" "workers.cloudflare.com" "www.lovelive-anime.jp")
            local f="/tmp/sb_sni_test.$$"; : > "$f"
            echo -e "${Y}[第1轮] 串行测速 ${#d[@]} 个域名，约需 16-20 秒...${R}" >&2
            local idx=1
            for i in "${d[@]}"; do
                local ms; ms=$(_test_tls_once "$i")
                echo "${ms} ${i}" >> "$f"
                if [ "$ms" -lt 9999 ] 2>/dev/null; then
                    echo -ne "  ${gl_hui}[${idx}/${#d[@]}]${R} ${i}: ${G}${ms}ms${R}\r" >&2
                else
                    echo -ne "  ${gl_hui}[${idx}/${#d[@]}]${R} ${i}: ${RED}超时${R}\r" >&2
                fi
                idx=$((idx + 1))
            done
            echo "" >&2
            local top5; top5=$(sort -n "$f" | head -5)
            echo -e "${Y}[第2轮] 对前 5 名各测 3 轮取最小值...${R}" >&2
            local f2="/tmp/sb_sni_test2.$$"; : > "$f2"
            while IFS=' ' read -r ms dom; do
                local best=9999 r
                for r in 1 2 3; do
                    local m; m=$(_test_tls_once "$dom")
                    if [ "$m" -lt "$best" ] 2>/dev/null; then best=$m; fi
                done
                echo "${best} ${dom}" >> "$f2"
                if [ "$best" -lt 9999 ] 2>/dev/null; then
                    echo -e "  ${dom}: ${G}${best}ms${R} (第1轮 ${ms}ms)" >&2
                else
                    echo -e "  ${dom}: ${RED}超时${R}" >&2
                fi
            done <<< "$top5"
            local b_d="www.microsoft.com" b_t=9999
            while IFS=' ' read -r t dom; do
                if [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null; then b_t=$t; b_d="$dom"; fi
            done < "$f2"
            rm -f "$f" "$f2"
            echo "" >&2
            echo -e "${G}✅ 优选结果: ${b_d} (最低 ${b_t}ms)${R}" >&2
            echo "$b_d"
            ;;
        3)
            read -e -p "输入域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

sb_check() {
    if ! command -v sing-box >/dev/null 2>&1; then echo -e "${RED}请先安装 Sing-Box 核心！${R}"; return 1; fi
    if ! command -v jq >/dev/null 2>&1; then echo -e "${RED}请先安装 jq (apt install jq -y)！${R}"; return 1; fi
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
        mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"
    fi
}

_save_node_meta() {
    local port="$1" name="$2" type="$3" pub_key="${4:-}" extra="${5:-}"
    _init_meta_file
    if [ -n "$pub_key" ]; then
        jq --arg p "$port" --arg n "$name" --arg t "$type" --arg pk "$pub_key" --arg ex "$extra" '.[$p] = {"name": $n, "type": $t, "pub_key": $pk, "extra": $ex}' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
    else
        jq --arg p "$port" --arg n "$name" --arg t "$type" --arg ex "$extra" '.[$p] = {"name": $n, "type": $t, "extra": $ex}' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"
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
    jq -r --arg p "$port" --arg field "$field" '.[$p][$field] // empty' "$META_FILE"
}

# ============================================================================
# ★ 防火墙放行
# ============================================================================
open_port() {
    local port=$1 proto="${2:-tcp}" opened=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${port}/${proto} >/dev/null 2>&1 && opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then opened=1
        elif iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then opened=1; fi
    fi
    if [ "$opened" -eq 1 ]; then echo -e "${G}  ✅ 已放行 ${proto^^} ${port}${R}"
    else echo -e "${Y}  ⚠ 无法自动放行 ${proto^^} ${port}，请手动检查云安全组${R}"; fi
}

open_port_both() { open_port "$1" "tcp"; open_port "$1" "udp"; }

open_port_range() {
    local start_port=$1 end_port=$2 proto="${3:-udp}" opened=0
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow ${start_port}:${end_port}/${proto} >/dev/null 2>&1 && opened=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port=${start_port}-${end_port}/${proto} >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && opened=1
    elif command -v iptables >/dev/null 2>&1; then
        if iptables -C INPUT -p ${proto} --dport ${start_port}:${end_port} -j ACCEPT >/dev/null 2>&1; then opened=1
        elif iptables -I INPUT -p ${proto} --dport ${start_port}:${end_port} -j ACCEPT >/dev/null 2>&1; then opened=1; fi
    fi
    if [ "$opened" -eq 1 ]; then echo -e "${G}  ✅ 已放行 ${proto^^} ${start_port}-${end_port}${R}"
    else echo -e "${Y}  ⚠ 无法自动放行 ${proto^^} ${start_port}-${end_port}，请手动检查云安全组${R}"; fi
}

# ============================================================================
# ★ 添加 VLESS Reality 节点
# ============================================================================
sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}========================================${R}"
    echo -e "${C}     添加 VLESS Reality 落地节点       ${R}"
    echo -e "${C}========================================${R}"
    read -e -p "监听端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]] && { echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    local sni; sni=$(select_sni)
    echo -e "${Y}正在生成 UUID ...${R}"
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [ -z "$uuid" ]; then echo -e "${RED}❌ UUID 生成失败！${R}"; read -rs -n 1 -p "按任意键返回..."; return 1; fi
    echo -e "${G}  ✅ UUID: ${uuid}${R}"
    echo -e "${Y}正在生成 Reality 密钥对 ...${R}"
    local keys_output priv_key pub_key
    keys_output=$(sing-box generate reality-keypair 2>&1)
    if [ $? -ne 0 ] || [ -z "$keys_output" ]; then
        echo -e "${RED}❌ Reality 密钥对生成失败！请检查 sing-box 版本${R}"
        read -rs -n 1 -p "按任意键返回..."; return 1
    fi
    priv_key=$(echo "$keys_output" | grep -i "PrivateKey" | awk '{print $2}')
    pub_key=$(echo "$keys_output" | grep -i "PublicKey" | awk '{print $2}')
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        echo -e "${RED}❌ 解析密钥失败！原始输出:${R}"; echo "$keys_output"
        read -rs -n 1 -p "按任意键返回..."; return 1
    fi
    echo -e "${G}  ✅ PrivateKey: ${priv_key}${R}"
    echo -e "${G}  ✅ PublicKey:  ${pub_key}${R}"
    local short_ids=("aabbccdd" "11223344" "deadbeef" "12345678" "abcdef01")
    local short_id=${short_ids[$((RANDOM % ${#short_ids[@]}))]}
    local dn="VLESS-Reality-${port}"
    read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    local ij
    ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" '{
        "type": "vless", "tag": ("vless-reality-" + ($p|tostring)), "listen": "::", "listen_port": $p,
        "users": [{"uuid": $u, "flow": "xtls-rprx-vision"}],
        "tls": {"enabled": true, "server_name": $s, "reality": {"enabled": true, "handshake": {"server": $s, "server_port": 443}, "private_key": $pk, "short_id": [$sid]}}
    }')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}----------------------------------------${R}"
        open_port_both "$port"
        _save_node_meta "$port" "$nn" "vless-reality" "$pub_key" "short_id=${short_id}"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        echo -e "${G}✅ VLESS Reality 节点添加成功！${R}"
        echo -e "${G}  端口: ${port} | 名称: ${nn}${R}"
        echo -e "${G}  PublicKey: ${pub_key}${R}"
        echo -e "${G}  short_id: ${short_id}${R}"
    else
        echo -e "${RED}❌ 配置校验失败！${R}"; sing-box check -c "$conf" 2>&1
        echo -e "${Y}正在回滚配置...${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
        _del_node_meta "$port"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# ★ 添加 VLESS+WS 节点
# ============================================================================
sb_add_vless_ws() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}========================================${R}"
    echo -e "${C}     添加 VLESS+WS 落地节点            ${R}"
    echo -e "${C}========================================${R}"
    read -e -p "监听端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]] && { echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    local ws_path="/$(openssl rand -hex 8)"
    read -e -p "WS Path (回车默认 ${ws_path}): " wp; [ -n "$wp" ] && ws_path="$wp"
    local dn="VLESS-WS-${port}"
    read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    echo -e "${Y}正在生成 UUID ...${R}"
    local uuid; uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [ -z "$uuid" ]; then echo -e "${RED}❌ UUID 生成失败！${R}"; read -rs -n 1 -p "按任意键返回..."; return 1; fi
    echo -e "${G}  ✅ UUID: ${uuid}${R}"
    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    local ij
    ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg wp "$ws_path" '{
        "type": "vless", "tag": ("vless-ws-" + ($p|tostring)), "listen": "::", "listen_port": $p,
        "users": [{"uuid": $u}],
        "transport": {"type": "ws", "path": $wp}
    }')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}----------------------------------------${R}"
        open_port_both "$port"
        _save_node_meta "$port" "$nn" "vless-ws" "" "path=${ws_path}"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        echo -e "${G}✅ VLESS+WS 节点添加成功！${R}"
        echo -e "${G}  端口: ${port} | Path: ${ws_path} | 名称: ${nn}${R}"
    else
        echo -e "${RED}❌ 配置校验失败！${R}"; sing-box check -c "$conf" 2>&1
        echo -e "${Y}正在回滚配置...${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
        _del_node_meta "$port"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# ★ 添加 Hysteria2 节点 (修复版: 兼容 sing-box 1.10+，不再使用 port_hop)
# ============================================================================
sb_add_hysteria2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}========================================${R}"
    echo -e "${C}     添加 Hysteria2 落地节点            ${R}"
    echo -e "${C}========================================${R}"
    read -e -p "起始端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]] && {
        echo -e "${RED}端口错误${R}"; read -rs -n 1 -p "按任意键返回..."; return
    }
    local listen_port_str="$port"
    read -e -p "端口跳跃结束端口 (留空=不启用): " hop_end
    if [[ -n "$hop_end" && "$hop_end" =~ ^[0-9]+$ && "$hop_end" -gt "$port" && "$hop_end" -le 65535 ]]; then
        listen_port_str="${port}-${hop_end}"
        echo -e "${G}  ✅ 端口跳跃范围: ${port} - ${hop_end}${R}"
    else
        echo -e "${Y}  ⚠ 不启用端口跳跃，仅监听 ${port}${R}"
    fi
    read -e -p "密码 (回车自动生成): " pwd
    if [ -z "$pwd" ]; then
        pwd=$(openssl rand -base64 24 | tr -d '\n/=+' | head -c 32)
        echo -e "${G}  ✅ 自动生成密码: ${pwd}${R}"
    fi
    local dn="Hysteria2-${port}"
    read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    echo -e "${Y}--- TLS 证书设置 ---${R}"
    echo -e "${G}1. 自动申请 Let's Encrypt 证书${R}"
    echo -e "${G}2. 手动指定证书路径${R}"
    echo -e "${G}3. 自签证书 (仅测试)${R}"
    read -e -p "请选择 (1/2/3): " tls_choice
    local tls_obj="" domain=""
    case "$tls_choice" in
        1)
            read -e -p "输入你的域名: " domain
            if [ -z "$domain" ]; then echo -e "${RED}域名不能为空${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
            tls_obj=$(jq -n --arg d "$domain" '{"enabled": true, "server_name": $d, "acme": {"domain": $d, "directory": "/etc/sing-box/acme", "email": "admin@\($d)"}}')
            ;;
        2)
            local cert_path key_path
            read -e -p "证书文件路径 (如 /a/b/cert.pem): " cert_path
            read -e -p "私钥文件路径 (如 /a/b/key.pem): " key_path
            if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then echo -e "${RED}证书文件不存在！${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
            tls_obj=$(jq -n --arg c "$cert_path" --arg k "$key_path" '{"enabled": true, "certificate_path": $c, "key_path": $k}')
            ;;
        3)
            local cert_dir="/etc/sing-box/certs/hy2-${port}"
            mkdir -p "$cert_dir"
            openssl req -x509 -nodes -days 3650 -newkey ec:<(openssl ecparam -name prime256v1 2>/dev/null) -keyout "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=hysteria2-node" 2>/dev/null
            tls_obj=$(jq -n --arg c "${cert_dir}/cert.pem" --arg k "${cert_dir}/key.pem" '{"enabled": true, "certificate_path": $c, "key_path": $k, "insecure": true}')
            echo -e "${Y}  ⚠ 自签证书，客户端需开启 allow_insecure${R}"
            ;;
        *) echo -e "${RED}无效选择${R}"; read -rs -n 1 -p "按任意键返回..."; return ;;
    esac
    sb_init_conf
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    # ★ 核心修复: listen_port 使用字符串端口范围，不再使用 port_hop 字段
    local ij
    ij=$(jq -n --arg lp "$listen_port_str" --arg pwd "$pwd" --argjson tls "$tls_obj" '{
        "type": "hysteria2", "tag": ("hysteria2-" + ($lp | split("-")[0])), "listen": "::", "listen_port": $lp,
        "up_mbps": 100, "down_mbps": 100, "users": [{"password": $pwd}], "tls": $tls
    }')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        echo -e "${Y}----------------------------------------${R}"
        open_port_both "$port"
        if [[ "$listen_port_str" == *-* ]]; then
            local hop_end_val="${listen_port_str#*-}"
            open_port_range "$port" "$hop_end_val" "tcp"
            open_port_range "$port" "$hop_end_val" "udp"
        fi
        _save_node_meta "$port" "$nn" "hysteria2" "" "listen_port_range=${listen_port_str};password=${pwd}"
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${RED}❌ 服务启动失败！错误日志如下：${R}"; journalctl -u sing-box -n 15 --no-pager 2>/dev/null
            echo -e "${Y}正在回滚配置...${R}"
            local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
            [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
            _del_node_meta "$port"; read -rs -n 1 -p "按任意键返回..."; return
        fi
        echo -e "${G}✅ Hysteria2 节点添加成功！${R}"
        echo -e "${G}  端口范围: ${listen_port_str}${R}"
        echo -e "${G}  密码: ${pwd}${R}"
        echo -e "${G}  名称: ${nn}${R}"
    else
        echo -e "${RED}❌ 配置校验失败！${R}"; sing-box check -c "$conf" 2>&1
        echo -e "${Y}正在回滚配置...${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        [ -n "$latest_bak" ] && mv "$latest_bak" "$conf" && echo -e "${Y}已从备份恢复原配置。${R}"
        _del_node_meta "$port"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# ★ 删除节点 (通过 tag 精确删除)
# ============================================================================
sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    _init_meta_file
    local node_count
    node_count=$(jq 'length' "$META_FILE" 2>/dev/null || echo 0)
    if [ "$node_count" -eq 0 ]; then echo -e "${Y}当前没有节点。${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    clear
    echo -e "${Y}         删除节点                        ${R}"
    echo -e "${Y}========================================${R}"
    local idx=1
    local ports=()
    while IFS= read -r port; do
        local nn=$(_get_node_meta "$port" "name")
        local tt=$(_get_node_meta "$port" "type")
        echo -e "${G}[${idx}] 端口: ${port} | 类型: ${tt} | 名称: ${nn}${R}"
        ports+=("$port")
        idx=$((idx + 1))
    done < <(jq -r 'keys[]' "$META_FILE" 2>/dev/null)
    echo -e "${Y}========================================${R}"
    read -e -p "请输入要删除的编号 (0返回): " del_idx
    [[ ! "$del_idx" =~ ^[0-9]+$ ]] && { echo -e "${RED}无效输入${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    [ "$del_idx" -eq 0 ] && return
    if [ "$del_idx" -lt 1 ] || [ "$del_idx" -gt ${#ports[@]} ]; then
        echo -e "${RED}编号超出范围${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    local del_port="${ports[$((del_idx - 1))]}"
    local del_name=$(_get_node_meta "$del_port" "name")
    local del_type=$(_get_node_meta "$del_port" "type")
    local del_tag=""
    case "$del_type" in
        vless-reality) del_tag="vless-reality-${del_port}" ;;
        vless-ws) del_tag="vless-ws-${del_port}" ;;
        hysteria2) del_tag="hysteria2-${del_port}" ;;
    esac
    local conf="/etc/sing-box/config.json"
    cp "$conf" "${conf}.bak.$(date +%s)"
    if [ -n "$del_tag" ]; then
        jq --arg t "$del_tag" '.inbounds = [.inbounds[] | select(.tag != $t)]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    fi
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        _del_node_meta "$del_port"
        systemctl restart sing-box; sleep 1
        echo -e "${G}✅ 已删除节点: ${del_name} (端口 ${del_port})${R}"
    else
        echo -e "${RED}❌ 删除后配置校验失败，回滚${R}"
        local latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
        [ -n "$latest_bak" ] && mv "$latest_bak" "$conf"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# ★ 查看节点列表 (从 meta 文件读取，彻底避免 jq 解析 config 的崩溃问题)
# ============================================================================
sb_list_nodes() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    _init_meta_file
    local node_count
    node_count=$(jq 'length' "$META_FILE" 2>/dev/null || echo 0)
    if [ "$node_count" -eq 0 ]; then echo -e "${Y}当前没有已添加的节点。${R}"; read -rs -n 1 -p "按任意键返回..."; return; fi
    clear
    echo -e "${Y}         当前节点列表                   ${R}"
    echo -e "${Y}========================================${R}"
    local idx=1
    while IFS= read -r port; do
        local nn=$(_get_node_meta "$port" "name")
        local tt=$(_get_node_meta "$port" "type")
        local display_type="$tt"
        case "$tt" in
            vless-reality) display_type="VLESS Reality" ;;
            vless-ws) display_type="VLESS+WS" ;;
            hysteria2) display_type="Hysteria2" ;;
        esac
        echo -e "${G}[${idx}] ${display_type} | 端口: ${port} | 名称: ${nn}${R}"
        # 显示额外信息
        local extra=$(_get_node_meta "$port" "extra")
        [ -n "$extra" ] && echo -e "${H}     ${extra}${R}"
        idx=$((idx + 1))
    done < <(jq -r 'keys[]' "$META_FILE" 2>/dev/null)
    echo -e "${Y}========================================${R}"
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# ★ 生成客户端链接 (base64 编码法，彻底解决 jq 多行 JSON 解析崩溃)
# ============================================================================
sb_gen_links() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then
        echo -e "${RED}配置文件不存在或格式错误！${R}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    local server_ip; server_ip=$(get_my_ip)
    if [ "$server_ip" = "未知IP" ]; then
        read -e -p "无法自动获取IP，请手动输入服务器IP或域名: " server_ip
        [ -z "$server_ip" ] && { echo -e "${RED}IP不能为空${R}"; read -rs -n 1 -p "按任意键返回..."; return; }
    fi
    clear
    echo -e "${Y}         生成客户端链接                 ${R}"
    echo -e "${Y}========================================${R}"
    echo -e "服务器地址: ${G}${server_ip}${R}"
    echo -e "${Y}========================================${R}"
    echo ""
    local link_count=0
    # ★★★ 核心修复：使用 @base64 编码每个 inbound，确保 while read 拿到完整对象 ★★★
    jq -r '.inbounds[] | @base64' "$conf" 2>/dev/null | while IFS= read -r b64_obj; do
        local obj; obj=$(echo "$b64_obj" | base64 -d 2>/dev/null)
        [ -z "$obj" ] && continue
        local inb_type; inb_type=$(echo "$obj" | jq -r '.type // empty' 2>/dev/null)
        [ -z "$inb_type" ] && continue
        local port; port=$(echo "$obj" | jq -r '.listen_port // empty' 2>/dev/null)
        [ -z "$port" ] && continue
        local tag; tag=$(echo "$obj" | jq -r '.tag // empty' 2>/dev/null)
        local node_name; node_name=$(_get_node_meta "$port" "name")
        [ -z "$node_name" ] && node_name="$tag"
        local link=""
        case "$inb_type" in
            vless)
                local uuid flow sni pub_key short_id
                uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                flow=$(echo "$obj" | jq -r '.users[0].flow // empty' 2>/dev/null)
                sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                pub_key=$(echo "$obj" | jq -r '.tls.reality.public_key // empty' 2>/dev/null)
                short_id=$(echo "$obj" | jq -r '.tls.reality.short_id[0] // empty' 2>/dev/null)
                if [ -n "$pub_key" ]; then
                    local ef es epk esid
                    ef=$(url_encode "${flow:-}"); es=$(url_encode "$sni")
                    epk=$(url_encode "$pub_key"); esid=$(url_encode "${short_id:-}")
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=${ef}&security=reality&sni=${es}&fp=chrome&pbk=${epk}&sid=${esid}&type=tcp#$(url_encode "${node_name}")"
                else
                    local ws_path ws_host tls_enabled
                    ws_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null)
                    ws_host=$(echo "$obj" | jq -r '.transport.headers.Host // empty' 2>/dev/null)
                    tls_enabled=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)
                    local ep eh; ep=$(url_encode "${ws_path:-/}"); eh=$(url_encode "${ws_host:-$sni}")
                    local security="none"; [ "$tls_enabled" = "true" ] && security="tls"
                    link="vless://${uuid}@${server_ip}:${port}?encryption=none&security=${security}&type=ws&host=${eh}&path=${ep}#$(url_encode "${node_name}")"
                fi
                ;;
            hysteria2)
                local hy2_pwd tls_sni tls_insecure
                hy2_pwd=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                tls_sni=$(echo "$obj" | jq -r '.tls.server_name // empty' 2>/dev/null)
                tls_insecure=$(echo "$obj" | jq -r '.tls.insecure // false' 2>/dev/null)
                local es2 ep2; es2=$(url_encode "${tls_sni:-}"); ep2=$(url_encode "$hy2_pwd")
                local insecure_param=""; [ "$tls_insecure" = "true" ] && insecure_param="&insecure=1"
                link="hysteria2://${ep2}@${server_ip}:${port}?sni=${es2}${insecure_param}#$(url_encode "${node_name}")"
                ;;
            vmess)
                local vm_uuid vm_aid vm_path vm_host vm_tls
                vm_uuid=$(echo "$obj" | jq -r '.users[0].uuid // empty' 2>/dev/null)
                vm_aid=$(echo "$obj" | jq -r '.users[0].alter_id // 0' 2>/dev/null)
                vm_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null)
                vm_host=$(echo "$obj" | jq -r '.transport.headers.Host // empty' 2>/dev/null)
                vm_tls=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)
                local vm_security="none"; [ "$vm_tls" = "true" ] && vm_security="tls"
                local vm_json
                vm_json=$(jq -n --arg v "2" --arg ps "${node_name}" --arg add "$server_ip" --argjson port "$port" --arg id "$vm_uuid" --arg aid "$vm_aid" --arg net "ws" --arg type "none" --arg host "${vm_host:-$server_ip}" --arg path "${vm_path:-/}" --arg tls "$vm_security" '{"v":$v,"ps":$ps,"add":$add,"port":$port,"id":$id,"aid":$aid,"scy":"auto","net":$net,"type":$type,"host":$host,"path":$path,"tls":$tls}')
                link="vmess://$(echo "$vm_json" | base64 -w0 2>/dev/null)"
                ;;
            trojan)
                local tr_pwd tr_path tr_host tr_tls
                tr_pwd=$(echo "$obj" | jq -r '.users[0].password // empty' 2>/dev/null)
                tr_path=$(echo "$obj" | jq -r '.transport.path // empty' 2>/dev/null)
                tr_host=$(echo "$obj" | jq -r '.transport.headers.Host // empty' 2>/dev/null)
                tr_tls=$(echo "$obj" | jq -r '.tls.enabled // false' 2>/dev/null)
                local tr_security="none"; [ "$tr_tls" = "true" ] && tr_security="tls"
                local etp eth etd
                etp=$(url_encode "${tr_path:-/}"); eth=$(url_encode "${tr_host:-$server_ip}"); etd=$(url_encode "$tr_pwd")
                link="trojan://${etd}@${server_ip}:${port}?security=${tr_security}&type=ws&host=${eth}&path=${etp}#$(url_encode "${node_name}")"
                ;;
            *) continue ;;
        esac
        if [ -n "$link" ]; then
            echo -e "${G}[$((link_count + 1))] ${node_name}${R}"
            echo -e "${H}    ${link}${R}"
            echo ""
            link_count=$((link_count + 1))
        fi
    done
    if [ "$link_count" -eq 0 ]; then
        echo -e "${Y}没有可生成链接的节点。${R}"
    else
        echo -e "${Y}========================================${R}"
        echo -e "${G}共生成 ${link_count} 条链接${R}"
        echo -e "${Y}========================================${R}"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# Sing-Box 节点管理主菜单
# ============================================================================
singbox_manager() {
    root_use
    while true; do
        clear
        echo -e "${C}========================================${R}"
        echo -e "${C}     Sing-Box 落地节点管理              ${R}"
        echo -e "${C}========================================${R}"
        local sb_status="${RED}未运行${R}"
        if systemctl is-active --quiet sing-box 2>/dev/null; then sb_status="${G}运行中${R}"; fi
        echo -e "核心状态: ${sb_status}"
        echo -e "--------------------"
        echo -e "${G}1. 添加 VLESS Reality 节点${R}"
        echo -e "${G}2. 添加 VLESS+WS 节点${R}"
        echo -e "${G}3. 添加 Hysteria2 节点${R}"
        echo -e "--------------------"
        echo -e "${Y}4. 查看节点列表${R}"
        echo -e "${Y}5. 查看节点与链接${R}"
        echo -e "${RED}6. 删除节点${R}"
        echo -e "--------------------"
        echo -e "7. 重启 Sing-Box"
        echo -e "8. 停止 Sing-Box"
        echo -e "9. 查看运行日志"
        echo -e "--------------------"
        echo "0. 返回主菜单"
        echo -e "${C}========================================${R}"
        read -e -p "请输入选择: " sb_choice
        case $sb_choice in
            1) sb_add_reality ;;
            2) sb_add_vless_ws ;;
            3) sb_add_hysteria2 ;;
            4) sb_list_nodes ;;
            5) sb_list_nodes; sb_gen_links ;;
            6) sb_del_node ;;
            7) systemctl restart sing-box && echo -e "${G}✅ 已重启${R}" || echo -e "${RED}❌ 重启失败${R}"; read -rs -n 1 -p "按任意键继续..." ;;
            8) systemctl stop sing-box && echo -e "${Y}已停止${R}" || echo -e "${RED}停止失败${R}"; read -rs -n 1 -p "按任意键继续..." ;;
            9) journalctl -u sing-box -n 30 --no-pager; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${RED}无效选择${R}"; read -rs -n 1 -p "按任意键继续..." ;;
        esac
    done
}

# ============================================================================
# 主菜单
# ============================================================================
main_menu() {
    while true; do
        clear
        echo -e "${gl_lv}========================================${gl_bai}"
        echo -e "${gl_lv}    Linux 服务器综合管理脚本            ${gl_bai}"
        echo -e "${gl_lv}========================================${gl_bai}"
        echo -e "1. 系统信息查询"
        echo -e "2. Linux 内核参数优化"
        echo -e "3. BBRv3 / XanMod 内核"
        echo -e "4. Swap 虚拟内存管理"
        echo -e "${gl_hong}5. Sing-Box 节点管理${gl_bai}"
        echo -e "0. 退出脚本"
        echo -e "${gl_lv}========================================${gl_bai}"
        read -e -p "请输入选择: " main_choice
        case $main_choice in
            1) show_sys_info ;;
            2) Kernel_optimize ;;
            3) bbrv3 ;;
            4) change_swap_size ;;
            5) singbox_manager ;;
            0|"") echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
        esac
    done
}

check_env
main_menu
