#!/usr/bin/env bash
# ============================================================================
# Linux 内核与网络调优模块 (YW Edition - Deep Optimized)
# 包含：系统信息查询 + 通用内核调优 + XanMod BBRv3 内核管理
# ============================================================================

# --- 颜色定义兼容 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_hong:=\033[31m}"

# --- 全局变量兼容 ---
: "${gh_proxy:=https://}"
: "${tiaoyou_moshi:=默认优化模式}"

# --- 辅助函数兼容 ---
check_swap() {
    local swap_total
    swap_total=$(free -m | awk '/Swap/{print $2}')
    if [ "$swap_total" -lt 512 ] && [ -f /swapfile ]; then
        echo "Swap file detected, skipping creation."
    elif [ "$swap_total" -lt 512 ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null 2>&1
        swapon /swapfile > /dev/null 2>&1
        echo "Swap created and activated."
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
        apt-get install -y "$@" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$@" >/dev/null 2>&1
    fi
}

server_reboot() {
    echo -e "${gl_lv}建议立即重启服务器以加载新内核...${gl_bai}"
    read -e -p "是否现在重启？(Y/N): " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

bbr_on() {
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    if [ -f "$CONF" ]; then
        sed -i '/net.core.default_qdisc/d' "$CONF"
        sed -i '/net.ipv4.tcp_congestion_control/d' "$CONF"
        if ! grep -q "tcp_congestion_control" "$CONF"; then
            cat >> "$CONF" << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        fi
        sysctl -p "$CONF" >/dev/null 2>&1
    fi
    return 0
}

# ============================================================================
# Helper Functions for Optimize
# ============================================================================

_get_mem_mb() {
	awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

root_use() {
	if [[ $EUID -ne 0 ]]; then
		echo -e "${gl_red}此脚本需要使用 root 权限运行${gl_bai}"
		exit 1
	fi
}

send_stats() {
	:
}

# ============================================================================
# NEW: System Information Query
# ============================================================================

show_system_info() {
    clear
    send_stats "系统信息查询"
    echo -e "\n${gl_huang}==================== 系统信息查询 ===================${gl_bai}"
    echo -e " ${gl_lv}当前内核版本:${gl_bai} $(uname -r)"
    echo -e " ${gl_lv}操作系统:    ${gl_bai}$(uname -o | awk '{print $3}') $(uname -m)"
    
    # OS Version
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        echo -e " ${gl_lv}系统版本:    ${gl_bai}${NAME} ${VERSION}"
    else
        echo -e " ${gl_lv}系统版本:    ${gl_bai}Unknown"
    fi

    echo -e " ${gl_lv}CPU信息:     ${gl_bai}"
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | grep -E "^(Architecture|CPU(s):|Model name:|Thread(s) per core:|Core\(s\) per socket:|Socket\(s\):)" 2>/dev/null
        # Add CPU speed if available
        echo -e " ${gl_huang}  CPU频率:     ${gl_bai}$(cat /proc/cpuinfo | grep "cpu MHz" | awk '{print $3}')"
    else
        echo -e " ${gl_huang}  (需安装 lscpu)${gl_bai}"
    fi

    echo -e " ${gl_lv}内存/交换空间: ${gl_bai}"
    free -h | head -2 | tail -1 # Show used/free/total line

    echo -e " ${gl_lv}磁盘使用:    ${gl_bai}"
    df -h | grep -E "^Filesystem|^/|^\-/" | head -5

    echo -e " ${gl_lv}网络接口:    ${gl_bai}"
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep inet | awk '{print " -> " $2}'
    else
        echo -e " ${gl_hui} (IP地址信息不可用)${gl_bai}"
    fi

    echo -e "\n${gl_huang}======================================================${gl_bai}\n"
    echo -n "按任意键返回主菜单..."
    read -n 1 -s
}

# ============================================================================
# Core Optimization Logic (General)
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-high}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    local MEM_MB=$(_get_mem_mb)

    echo -e "${gl_lv}切换到${mode_name}...${gl_bai}"

    # 默认变量初始化
    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG
    local PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr"
    local QDISC="fq"
    local UDP_RMEM_MIN=16384

    case "$scene" in
        high|stream|game)
            # --- 专家级高性能/直播/游戏参数 ---
            SWAPPINESS=10
            DIRTY_RATIO=15
            DIRTY_BG_RATIO=5
            OVERCOMMIT=1
            VFS_PRESSURE=50
            MIN_FREE_KB=131072

            # 网络缓冲区：针对高吞吐优化
            RMEM_MAX=134217728 # 128MB
            WMEM_MAX=134217728 # 128MB
            TCP_RMEM="4096 87380 67108864"
            TCP_WMEM="4096 65536 67108864"
            
            SOMAXCONN=65535
            BACKLOG=250000
            SYN_BACKLOG=8192
            PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0
            THP="never"
            NUMA=0
            
            FIN_TIMEOUT=10
            KEEPALIVE_TIME=300
            KEEPALIVE_INTVL=30
            KEEPALIVE_PROBES=5
            TCP_NOTSENT_LOWAT=16384
            TCP_FASTOPEN=3
            TCP_TW_REUSE=1
            TCP_MTU_PROBING=1

            if [ "$scene" = "stream" ] || [ "$scene" = "game" ]; then
				UDP_RMEM_MIN=256000 # 直播/游戏专用加大UDP缓冲
				GAME_EXTRA="
net.ipv4.udp_rmem_min = 256000
net.ipv4.udp_wmem_min = 256000
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
"
            else
                GAME_EXTRA="
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
"
            fi
            STREAM_EXTRA="" # High mode doesn't need extra UDP specific tweaks usually, but inherits base

            ;;
            
        web)
            # --- Web 服务器优化：高并发 ---
            SWAPPINESS=10
            DIRTY_RATIO=20
            DIRTY_BG_RATIO=10
            OVERCOMMIT=1
            VFS_PRESSURE=50
            RMEM_MAX=67108864
            WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"
            TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535
            BACKLOG=250000
            SYN_BACKLOG=8192
            PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0
            THP="never"
            NUMA=0
            FIN_TIMEOUT=15
            KEEPALIVE_TIME=600
            KEEPALIVE_INTVL=60
            KEEPALIVE_PROBES=5
            TCP_NOTSENT_LOWAT=16384
            TCP_FASTOPEN=3
            TCP_TW_REUSE=1
            TCP_MTU_PROBING=1
            
            GAME_EXTRA=""
            STREAM_EXTRA=""
            ;;

        balanced)
            # --- 均衡模式 ---
            SWAPPINESS=30
            DIRTY_RATIO=20
            DIRTY_BG_RATIO=10
            OVERCOMMIT=0
            VFS_PRESSURE=75
            RMEM_MAX=16777216
            WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"
            TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096
            BACKLOG=5000
            SYN_BACKLOG=4096
            PORT_RANGE="1024 49151"
            SCHED_AUTOGROUP=1
            THP="always"
            NUMA=1
            FIN_TIMEOUT=30
            KEEPALIVE_TIME=600
            KEEPALIVE_INTVL=60
            KEEPALIVE_PROBES=5
            
            GAME_EXTRA=""
            STREAM_EXTRA=""
            ;;
            
        *)
            echo -e "${gl_red}错误: 未知场景 ${scene}${gl_bai}"
            return 1
            ;;
    esac

    # --- 根据内存大小自适应调整 ---
    if [ "$MEM_MB" -ge 16384 ]; then
        MIN_FREE_KB=131072
        [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB" -ge 4096 ]; then
        MIN_FREE_KB=65536
    elif [ "$MEM_MB" -ge 1024 ]; then
        MIN_FREE_KB=32768
        if [ "$scene" != "balanced" ]; then
            RMEM_MAX=16777216
            WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"
            TCP_WMEM="4096 65536 16777216"
        fi
    else
        MIN_FREE_KB=16384
        SWAPPINESS=30
        OVERCOMMIT=0
        RMEM_MAX=4194304
        WMEM_MAX=4194304
        TCP_RMEM="4096 32768 4194304"
        TCP_WMEM="4096 32768 4194304"
        SOMAXCONN=1024
        BACKLOG=1000
    fi

    # --- 检测 BBR 支持 ---
    local KVER
    KVER=$(uname -r | grep -oP '^\d+\.\d+')
    if printf '%s\n%s' "4.9" "$KVER" | sort -V -C; then
        if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
            modprobe tcp_bbr 2>/dev/null
        fi
        if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            CC="cubic"
            QDISC="fq_codel"
        fi
    else
        CC="cubic"
        QDISC="fq_codel"
    fi

    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"

    echo -e "${gl_lv}写入优化配置...${gl_bai}"
    cat > "$CONF" << SYSCTL
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

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

# ── UDP 缓冲区 (直播/游戏优先) ──
net.ipv4.udp_rmem_min = $UDP_RMEM_MIN
net.ipv4.udp_wmem_min = $UDP_RMEM_MIN

# ── 连接队列 ──
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# ── TCP 连接优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 16384

# ── 端口与内存 ──
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $((MEM_MB * 1024 / 8)) $((MEM_MB * 1024 / 4)) $((MEM_MB * 1024 / 2))
net.ipv4.tcp_max_orphans = 32768

# ── 虚拟内存 ──
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

# ── CPU/内核调度 ──
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
\$([ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa_balancing 不支持")

# ── 安全防护 ──
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_ignores_broadcasts = 1
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
\$(if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
echo "net.netfilter.nf_conntrack_max = \$((SOMAXCONN * 32))"
echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
else
echo "# conntrack 未启用"
fi)
$GAME_EXTRA
$STREAM_EXTRA
SYSCTL

    echo -e "${gl_lv}应用优化参数...${gl_bai}"
    local applied=0 skipped=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if sysctl -w "$line" >/dev/null 2>&1; then
            applied=$((applied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < "$CONF"
    echo -e "${gl_lv}已应用 ${applied} 项参数${skipped:+，跳过 ${skipped} 项不支持的参数}${gl_bai}"

    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITS'

# YW-optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
    fi

    if [ "$CC" = "bbr" ]; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    fi

    echo -e "${gl_lv}${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
    echo -e "${gl_lv}内存: ${MEM_MB}MB | 拥塞算法: ${CC} | 队列: ${QDISC}${gl_bai}"
}

# ============================================================================
# BBRv3 (XanMod) Management
# ============================================================================

bbrv3() {
    root_use
    send_stats "bbrv3管理"

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

        if [ -z "$os_codename" ]; then
            echo "无法获取系统代号，无法配置XanMod源"
            return 1
        fi

        install wget gnupg ca-certificates
        mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
        if ! wget -qO - "$key_url" | gpg --dearmor -o "$keyring" --yes; then
            echo "官方密钥下载失败，尝试备用下载源..."
            wget -qO - "$fallback_key_url" | gpg --dearmor -o "$keyring" --yes || return 1
        fi
        chmod 644 "$keyring"
        echo "deb [signed-by=$keyring] http://deb.xanmod.org $os_codename main" > "$list_file"
    }

    xanmod_detect_psabi_level() {
        local psabi_output=""
        psabi_output=$(awk 'BEGIN {
            while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
            if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
            if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
            if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
            if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
            if (level > 0) { print level; exit }
            exit 1
        }' /proc/cpuinfo 2>/dev/null) || return 1
        printf '%s' "$psabi_output" | tr -dc '0-9' | head -c 1
    }

    xanmod_package_available() {
        local package="$1"
        apt-cache policy "$package" 2>/dev/null | grep -q 'Candidate: [^ ]'
    }

    xanmod_detect_package() {
        local psabi_level=""
        local level=""
        local package=""
        local prefix_list="linux-xanmod linux-xanmod-lts"

        psabi_level=$(xanmod_detect_psabi_level) || return 1
        [ -n "$psabi_level" ] || return 1
        [ "$psabi_level" -gt 3 ] && psabi_level=3

        apt update -y >/dev/null 2>&1

        for prefix in $prefix_list; do
            level="$psabi_level"
            while [ "$level" -ge 1 ]; do
                package="${prefix}-x64v${level}"
                if xanmod_package_available "$package"; then
                    if [ "$level" != "$psabi_level" ] || [ "$prefix" = "linux-xanmod-lts" ]; then
                        echo "已自动匹配合适安装包: $package" >&2
                    fi
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
        local package=""

        check_disk_space 3
        check_swap
        xanmod_add_repo || {
            echo "XanMod官方仓库配置失败，请稍后重试"
            return 1
        }

        package=$(xanmod_detect_package) || {
            echo "无法识别当前CPU或找不到匹配内核包，已取消安装"
            return 1
        }

        apt update -y
        if [ "$action" = "update" ]; then
            apt install -y --only-upgrade "$package" || apt install -y "$package" || {
                echo "XanMod内核更新失败，请检查软件源或稍后重试"
                return 1
            }
        else
            apt install -y "$package" || {
                echo "XanMod内核安装失败，请检查软件源或稍后重试"
                return 1
            }
        fi

        bbr_on || {
            echo "BBR3参数写入失败，请检查系统配置"
            return 1
        }
        echo "XanMod BBRv3内核处理完成。重启后生效"
        server_reboot
    }

    xanmod_uninstall() {
        apt purge -y 'linux-*xanmod*'
        apt autoremove -y
        update-grub 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/xanmod-release.list
        rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
        echo "XanMod内核已卸载。重启后生效"
        server_reboot
    }

    local cpu_arch=$(uname -m)
    if [ "$cpu_arch" = "aarch64" ]; then
        bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh)
        break_end
        linux_Settings
    fi

    if [ -r /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ]; then
            echo "当前环境不支持，仅支持Debian和Ubuntu系统"
            break_end
            linux_Settings
        fi
    else
        echo "无法确定操作系统类型"
        break_end
        linux_Settings
    fi

    if xanmod_installed; then
        while true do
            local kernel_version=$(uname -r)
            echo "您已安装xanmod的BBRv3内核"
            echo "当前内核版本: $kernel_version"

            echo ""
            echo "内核管理"
            echo "------------------------"
            echo "1. 更新BBRv3内核              2. 卸载BBRv3内核"
            echo "------------------------"
            echo "0. 返回上一级选单"
            echo "------------------------"
            read -e -p "请输入你的选择: " sub_choice

            case $sub_choice in
                1)
                    xanmod_install_or_update update
                    ;;
                2)
                    xanmod_uninstall
                    ;;
                *)
                    break
                    ;;
            esac
        done
    else
        local choice=""
        read -e -p "确定安装BBR3内核吗？(Y/N): " choice

        case "$choice" in
            [Yy])
                xanmod_install_or_update install
                ;;
            [Nn])
                echo "已取消"
                ;;
            *)
                echo "无效的选择，请输入 Y 或 N。"
                ;;
        esac
    fi
}

# ============================================================================
# Interactive Menu (General)
# ============================================================================

Kernel_optimize() {
    root_use
    local current_mode="未优化"
    local conf_file="/etc/sysctl.d/99-yw-optimize.conf"
    
    if [ -f "$conf_file" ]; then
        local raw_mode=$(grep "^# 模式:" "$conf_file" 2>/dev/null | sed 's/^# 模式: //')
        if [ -n "$raw_mode" ]; then
            current_mode=$(echo "$raw_mode" | awk -F'|' '{print $1}' | xargs)
        else
            current_mode="系统优化已启用"
        fi
    fi

    while true do
        clear
        send_stats "内核调优菜单"
        
        echo -e "\n${gl_huang}==================== Linux内核调优 ===================${gl_bai}"
        echo -e " ${gl_lv}当前状态: ${gl_bai}${current_mode}"
        echo -e " ${gl_lv}内核版本: ${gl_bai}$(uname -r)"
        echo -e " ${gl_lv}内存大小: ${gl_bai}$(awk '/MemTotal/{printf "%.2f GB", $2/1024/1024}' /proc/meminfo)"
        echo -e "\n${gl_huang}==================== 主菜单选项 =======================${gl_bai}"
        echo -e " ${gl_lv}1. 系统信息查询        : 查看CPU、内存、磁盘等系统详细信息"
        echo -e " ${gl_lv}2. Linux内核参数优化    : 进入内核调优选择菜单"
        echo -e "\n${gl_huang}=======================================================${gl_bai}\n"
        echo -n "请输入你的选择 (1-2): "
        read -e -p "" sub_choice
        
        case $sub_choice in
            1)
                show_system_info
                ;;
            2)
                # Sub-menu for Kernel Optimization
                local sub_mode=""
                clear
                echo -e "\n${gl_huang}==================== 内核参数优化 =====================${gl_bai}"
                echo -e " ${gl_lv}1. 高性能优化模式       : 最大化性能，适合游戏/推流"
                echo -e " ${gl_lv}2. 均衡优化模式         : 平衡性能与资源，适合日常使用"
                echo -e " ${gl_lv}3. 网站优化模式         : 高并发Web服务器专用优化"
                echo -e " ${gl_lv}4. 直播优化模式         : 直播推流专用优化"
                echo -e " ${gl_lv}5. 游戏服优化模式       : 游戏服务器专用优化"
                echo -e " ${gl_lv}6. BBRv3 内核安装       : 安装 XanMod BBRv3 内核 (仅Debian/Ubuntu)"
                echo -e " ${gl_lv}7. 还原默认设置         : 将内核参数还原为默认配置"
                echo -e " ${gl_lv}0. 返回主菜单           : 返回上一级"
                echo -e "\n${gl_huang}=======================================================${gl_bai}\n"
                echo -n "请输入你的选择 (0-7): "
                read -e -p "" opt_choice

                case $opt_choice in
                    1)
                        local tiaoyou_moshi="高性能优化模式"
                        _kernel_optimize_core "${tiaoyou_moshi}" "high"
                        ;;
                    2)
                        local tiaoyou_moshi="均衡优化模式"
                        _kernel_optimize_core "${tiaoyou_moshi}" "balanced"
                        ;;
                    3)
                        local tiaoyou_moshi="网站优化模式"
                        _kernel_optimize_core "${tiaoyou_moshi}" "web"
                        ;;
                    4)
                        local tiaoyou_moshi="直播优化模式"
                        _kernel_optimize_core "${tiaoyou_moshi}" "stream"
                        ;;
                    5)
                        local tiaoyou_moshi="游戏服优化模式"
                        _kernel_optimize_core "${tiaoyou_moshi}" "game"
                        ;;
                    6)
                        bbrv3
                        ;;
                    7)
                        restore_defaults
                        ;;
                    0)
                        ;;
                    *)
                        echo -e "${gl_red}无效选择${gl_bai}"
                        ;;
                esac
                ;;
            *)
                echo -e "${gl_red}无效选择${gl_bai}"
                ;;
        esac
    done
}

# ============================================================================
# Public API Functions
# ============================================================================

_kernel_optimize_core() {
    local mode_name="$1"
    local scene="${2:-high}"
    local CONF="/etc/sysctl.d/99-yw-optimize.conf"
    local MEM_MB=$(_get_mem_mb)

    echo -e "${gl_lv}切换到${mode_name}...${gl_bai}"

    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
    local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
    local SOMAXCONN BACKLOG SYN_BACKLOG
    local PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
    local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr"
    local QDISC="fq"
    local UDP_RMEM_MIN=16384

    case "$scene" in
        high|stream|game)
            SWAPPINESS=10
            DIRTY_RATIO=15
            DIRTY_BG_RATIO=5
            OVERCOMMIT=1
            VFS_PRESSURE=50
            MIN_FREE_KB=131072

            # 网络缓冲区：针对高吞吐优化
            RMEM_MAX=134217728 # 128MB
            WMEM_MAX=134217728 # 128MB
            TCP_RMEM="4096 87380 67108864"
            TCP_WMEM="4096 65536 67108864"
            
            SOMAXCONN=65535
            BACKLOG=250000
            SYN_BACKLOG=8192
            PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0
            THP="never"
            NUMA=0
            
            FIN_TIMEOUT=10
            KEEPALIVE_TIME=300
            KEEPALIVE_INTVL=30
            KEEPALIVE_PROBES=5
            TCP_NOTSENT_LOWAT=16384
            TCP_FASTOPEN=3
            TCP_TW_REUSE=1
            TCP_MTU_PROBING=1

            if [ "$scene" = "stream" ] || [ "$scene" = "game" ]; then
                UDP_RMEM_MIN=256000
                GAME_EXTRA="
net.ipv4.udp_rmem_min = 256000
net.ipv4.udp_wmem_min = 256000
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
"
            else
                GAME_EXTRA="
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
"
            fi
            STREAM_EXTRA=""
            ;;
            
        web)
            SWAPPINESS=10
            DIRTY_RATIO=20
            DIRTY_BG_RATIO=10
            OVERCOMMIT=1
            VFS_PRESSURE=50
            RMEM_MAX=67108864
            WMEM_MAX=67108864
            TCP_RMEM="4096 87380 67108864"
            TCP_WMEM="4096 65536 67108864"
            SOMAXCONN=65535
            BACKLOG=250000
            SYN_BACKLOG=8192
            PORT_RANGE="1024 65535"
            SCHED_AUTOGROUP=0
            THP="never"
            NUMA=0
            FIN_TIMEOUT=15
            KEEPALIVE_TIME=600
            KEEPALIVE_INTVL=60
            KEEPALIVE_PROBES=5
            TCP_NOTSENT_LOWAT=16384
            TCP_FASTOPEN=3
            TCP_TW_REUSE=1
            TCP_MTU_PROBING=1
            GAME_EXTRA=""
            STREAM_EXTRA=""
            ;;

        balanced)
            SWAPPINESS=30
            DIRTY_RATIO=20
            DIRTY_BG_RATIO=10
            OVERCOMMIT=0
            VFS_PRESSURE=75
            RMEM_MAX=16777216
            WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"
            TCP_WMEM="4096 65536 16777216"
            SOMAXCONN=4096
            BACKLOG=5000
            SYN_BACKLOG=4096
            PORT_RANGE="1024 49151"
            SCHED_AUTOGROUP=1
            THP="always"
            NUMA=1
            FIN_TIMEOUT=30
            KEEPALIVE_TIME=600
            KEEPALIVE_INTVL=60
            KEEPALIVE_PROBES=5
            GAME_EXTRA=""
            STREAM_EXTRA=""
            ;;
            
        *)
            echo -e "${gl_red}错误: 未知场景 ${scene}${gl_bai}"
            return 1
            ;;
    esac

    # --- 根据内存大小自适应调整 ---
    if [ "$MEM_MB" -ge 16384 ]; then
        MIN_FREE_KB=131072
        [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB" -ge 4096 ]; then
        MIN_FREE_KB=65536
    elif [ "$MEM_MB" -ge 1024 ]; then
        MIN_FREE_KB=32768
        if [ "$scene" != "balanced" ]; then
            RMEM_MAX=16777216
            WMEM_MAX=16777216
            TCP_RMEM="4096 87380 16777216"
            TCP_WMEM="4096 65536 16777216"
        fi
    else
        MIN_FREE_KB=16384
        SWAPPINESS=30
        OVERCOMMIT=0
        RMEM_MAX=4194304
        WMEM_MAX=4194304
        TCP_RMEM="4096 32768 4194304"
        TCP_WMEM="4096 32768 4194304"
        SOMAXCONN=1024
        BACKLOG=1000
    fi

    # --- 检测 BBR 支持 ---
    local KVER
    KVER=$(uname -r | grep -oP '^\d+\.\d+')
    if printf '%s\n%s' "4.9" "$KVER" | sort -V -C; then
        if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
            modprobe tcp_bbr 2>/dev/null
        fi
        if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
            CC="cubic"
            QDISC="fq_codel"
        fi
    else
        CC="cubic"
        QDISC="fq_codel"
    fi

    [ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"

    echo -e "${gl_lv}写入优化配置...${gl_bai}"
    cat > "$CONF" << SYSCTL
# YW Linux 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

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

# ── UDP 缓冲区 (直播/游戏优先) ──
net.ipv4.udp_rmem_min = $UDP_RMEM_MIN
net.ipv4.udp_wmem_min = $UDP_RMEM_MIN

# ── 连接队列 ──
net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

# ── TCP 连接优化 ──
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_keepalive_time = $KEEPALIVE_TIME
net.ipv4.tcp_keepalive_intvl = $KEEPALIVE_INTVL
net.ipv4.tcp_keepalive_probes = $KEEPALIVE_PROBES
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_notsent_lowat = 16384

# ── 端口与内存 ──
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $((MEM_MB * 1024 / 8)) $((MEM_MB * 1024 / 4)) $((MEM_MB * 1024 / 2))
net.ipv4.tcp_max_orphans = 32768

# ── 虚拟内存 ──
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

# ── CPU/内核调度 ──
kernel.sched_autogroup_enabled = $SCHED_AUTOGROUP
\$([ -f /proc/sys/kernel/numa_balancing ] && echo "kernel.numa_balancing = $NUMA" || echo "# numa_balancing 不支持")

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
\$(if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
echo "net.netfilter.nf_conntrack_max = \$((SOMAXCONN * 32))"
echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"
echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"
echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"
echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"
else
echo "# conntrack 未启用"
fi)
$GAME_EXTRA
$STREAM_EXTRA
SYSCTL

    echo -e "${gl_lv}应用优化参数...${gl_bai}"
    local applied=0 skipped=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        if sysctl -w "$line" >/dev/null 2>&1; then
            applied=$((applied + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < "$CONF"
    echo -e "${gl_lv}已应用 ${applied} 项参数${skipped:+，跳过 ${skipped} 项不支持的参数}${gl_bai}"

    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    fi

    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITS'

# YW-optimize
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS
    fi

    if [ "$CC" = "bbr" ]; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    fi

    echo -e "${gl_lv}${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
    echo -e "${gl_lv}内存: ${MEM_MB}MB | 拥塞算法: ${CC} | 队列: ${QDISC}${gl_bai}"
}

# ============================================================================
# Public API Functions
# ============================================================================

restore_defaults() {
    echo -e "${gl_lv}还原到默认设置...${gl_bai}"

    local CONF="/etc/sysctl.d/99-yw-optimize.conf"

    rm -f "$CONF"
    rm -f /etc/sysctl.d/99-network-optimize.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
    sysctl --system 2>/dev/null | tail -1
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && \
        echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    if grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then
        sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf
    fi
    rm -f /etc/modules-load.d/bbr.conf 2>/dev/null

    echo -e "${gl_lv}系统已还原到默认设置${gl_bai}"
}

# ============================================================================
# Entry Point
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    Kernel_optimize
fi
