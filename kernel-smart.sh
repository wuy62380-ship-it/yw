#!/usr/bin/env bash
# ============================================================================
# Linux YW内核与网络调优模块 (YW全场景极限特化 + 中转网关专属)
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

# ★ 新增：环境自检，自动安装 curl 和 jq 等必备工具
check_env() {
    local need_update=0
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到未安装 curl，正在自动安装...${gl_bai}"
        need_update=1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到未安装 jq，正在自动安装...${gl_bai}"
        need_update=1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到未安装 openssl，正在自动安装...${gl_bai}"
        need_update=1
    fi

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
    if [ -f /swapfile ] && [ "$swap_total" -lt 512 ]; then swapon /swapfile >/dev/null 2>&1; swap_total=$(free -m | awk '/Swap/{print $2}'); [ "$swap_total" -ge 512 ] && return 0; fi
    if df / | grep -q "/$" && [ ! -f /etc/pve/.version ]; then
        echo -e "${gl_huang}正在创建 512MB 应急 Swap...${gl_bai}"; dd if=/dev/zero of=/swapfile bs=1M count=512 2>/dev/null; chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
        grep -q "/swapfile none" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo -e "${gl_lv}✅ 应急 Swap 创建完成。${gl_bai}"
    fi
}

auto_setup_zram() {
    if grep -q "/dev/zram" /proc/swaps 2>/dev/null; then echo -e "${gl_lv}检测到 zram 已在运行，跳过配置。${gl_bai}"; return 0; fi
    echo -e "${gl_lv}正在尝试自动配置 zram 替代 zswap...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        if ! command -v zramctl >/dev/null 2>&1; then install zram-tools || return 1; fi
        sed -i 's/^ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null; sed -i 's/^PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null
        systemctl enable zramswap >/dev/null 2>&1; systemctl restart zramswap >/dev/null 2>&1
        grep -q "/dev/zram" /proc/swaps 2>/dev/null && echo -e "${gl_lv}✅ zram 配置成功并已启动！${gl_bai}" || echo -e "${gl_huang}zram 启动失败，可能内核不支持。${gl_bai}"
    elif command -v yum >/dev/null 2>&1; then echo -e "${gl_huang}CentOS/RHEL 建议手动安装 zram-generator${gl_bai}"; fi
}

check_disk_space() { local a=$(df -m / | tail -1 | awk '{print $4}'); if [ "$a" -lt "$1" ]; then echo -e "${gl_red}磁盘不足，需 ${1}MB，可用 ${a}MB${gl_bai}"; return 1; fi; return 0; }
install() { if command -v apt >/dev/null 2>&1; then apt-get install -y "$@" >/tmp/yw_apt.log 2>&1 || { echo -e "${gl_red}APT 失败${gl_bai}"; return 1; }; elif command -v yum >/dev/null 2>&1; then yum install -y "$@" >/tmp/yw_yum.log 2>/dev/null || { echo -e "${gl_red}YUM 失败${gl_bai}"; return 1; }; fi; }
server_reboot() { echo -e "${gl_lv}建议立即重启服务器...${gl_bai}"; read -e -p "是否现在重启？: "; [[ "$REPLY" =~ ^[Yy]$ ]] && reboot; }
bbr_on() { local C="/etc/sysctl.d/99-yw-optimize.conf"; [ -f "$C" ] && { grep -q "tcp_congestion_control = bbr" "$C" 2>/dev/null || { sed -i '/net.ipv4.tcp_congestion_control/d' "$C"; echo "net.ipv4.tcp_congestion_control = bbr" >> "$C"; }; sysctl -p "$C" >/dev/null 2>&1; }; }
break_end() { local c="$1"; [ -z "$c" ] || [ "$c" = "0" ] || [ "$c" = "return" ]; }

change_swap_size() {
    local s="/swapfile" c=$(free -m | awk '/Swap/{print $2}'); clear
    echo -e "${gl_huang}========================================${gl_bai}\n${gl_huang}        Swap 虚拟内存管理               ${gl_bai}\n${gl_huang}========================================${gl_bai}"
    echo -e "当前 Swap: ${gl_lv}${c} MB${gl_bai} | 可用磁盘: $(df -m / | tail -1 | awk '{print $4}') MB\n"
    echo -e "1. 1 GB\n2. 2 GB\n3. 4 GB\n4. 6 GB\n5. 自定义\n6. 移除 Swap\n0. 返回\n${gl_huang}----------------------------------------${gl_bai}"
    read -e -p "选择: " ch; local sz=""
    case $ch in 1) sz=1024;; 2) sz=2048;; 3) sz=4096;; 4) sz=6144;; 5) read -e -p "大小(MB,最小512): " sz; [[ ! "$sz" =~ ^[0-9]+$ || "$sz" -lt 512 ]] && { echo -e "${gl_red}错误${gl_bai}"; read -rs -n 1 -p ""; return; };; 6) [ "$c" -gt 0 ] && { swapoff "$s" 2>/dev/null; rm -f "$s"; sed -i '/swapfile/d' /etc/fstab; echo -e "${gl_lv}已移除${gl_bai}"; }; read -rs -n 1 -p ""; return;; 0|"") return;; *) echo -e "${gl_red}无效${gl_bai}"; read -rs -n 1 -p ""; return;; esac
    [ -n "$sz" ] && { [ "$(df -m / | tail -1 | awk '{print $4}')" -lt $((sz+100)) ] && { echo -e "${gl_red}空间不足${gl_bai}"; read -rs -n 1 -p ""; return; }; echo -e "${gl_lv}创建中...${gl_bai}"; swapoff "$s" 2>/dev/null; dd if=/dev/zero of="$s" bs=1M count=$sz 2>/dev/null; chmod 600 "$s"; mkswap "$s" >/dev/null 2>&1; swapon "$s" >/dev/null 2>&1; grep -q "$s" /etc/fstab 2>/dev/null || echo "$s none swap sw 0 0" >> /etc/fstab; echo -e "${gl_lv}✅ 成功: ${sz}MB${gl_bai}"; }; read -rs -n 1 -p ""
}

# ============================================================================
# 核心优化逻辑
# ============================================================================
_kernel_optimize_core() {
    local mode_name="$1" scene="${2:-high}" CONF="/etc/sysctl.d/99-yw-optimize.conf"
    echo -e "${gl_lv}切换到${mode_name}...${gl_bai}"
    local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM SOMAXCONN BACKLOG SYN_BACKLOG PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES
    local CC="bbr" QDISC="fq" UDP_RMEM_MIN=16384 TCP_NOTSENT_LOWAT=16384 TCP_FASTOPEN=3 TCP_TW_REUSE=1 TCP_MTU_PROBING=1 GAME_EXTRA="" STREAM_EXTRA="" HIGH_EXTRA="" WEB_EXTRA="" BALANCED_EXTRA="" GATEWAY_EXTRA="" TCP_SLOW_START_AFTER_IDLE=0 TCP_ECN=0 
    case "$scene" in
        high) SWAPPINESS=10;OVERCOMMIT=1;VFS_PRESSURE=50;DIRTY_RATIO=40;DIRTY_BG_RATIO=10;MIN_FREE_KB=131072;RMEM_MAX=134217728;WMEM_MAX=134217728;TCP_RMEM="4096 87380 67108864";TCP_WMEM="4096 65536 67108864";SOMAXCONN=65535;BACKLOG=250000;SYN_BACKLOG=8192;PORT_RANGE="1024 65535";SCHED_AUTOGROUP=0;THP="never";NUMA=0;FIN_TIMEOUT=10;KEEPALIVE_TIME=300;KEEPALIVE_INTVL=30;KEEPALIVE_PROBES=5;HIGH_EXTRA=$'vm.dirty_ratio = 40\nvm.dirty_background_ratio = 10' ;;
        web) SWAPPINESS=10;DIRTY_RATIO=20;DIRTY_BG_RATIO=10;OVERCOMMIT=1;VFS_PRESSURE=50;MIN_FREE_KB=131072;RMEM_MAX=67108864;WMEM_MAX=67108864;TCP_RMEM="4096 87380 67108864";TCP_WMEM="4096 65536 67108864";SOMAXCONN=65535;BACKLOG=250000;SYN_BACKLOG=8192;PORT_RANGE="1024 65535";SCHED_AUTOGROUP=0;THP="never";NUMA=0;FIN_TIMEOUT=15;KEEPALIVE_TIME=120;KEEPALIVE_INTVL=15;KEEPALIVE_PROBES=3;WEB_EXTRA=$'net.ipv4.tcp_max_tw_buckets = 524288\nnet.ipv4.tcp_max_syn_backlog = 16384' ;;
        stream) SWAPPINESS=10;DIRTY_RATIO=15;DIRTY_BG_RATIO=5;OVERCOMMIT=1;VFS_PRESSURE=50;MIN_FREE_KB=131072;RMEM_MAX=134217728;WMEM_MAX=134217728;TCP_RMEM="4096 87380 67108864";TCP_WMEM="4096 65536 67108864";SOMAXCONN=65535;BACKLOG=250000;SYN_BACKLOG=8192;PORT_RANGE="1024 65535";SCHED_AUTOGROUP=0;THP="never";NUMA=0;FIN_TIMEOUT=10;KEEPALIVE_TIME=300;KEEPALIVE_INTVL=30;KEEPALIVE_PROBES=5;UDP_RMEM_MIN=131072;STREAM_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.ipv4.udp_rmem_max = 16777216\nnet.ipv4.udp_wmem_max = 16777216\nnet.core.netdev_budget = 1200\nnet.core.netdev_max_backlog = 500000' ;;
        game) SWAPPINESS=10;DIRTY_RATIO=10;DIRTY_BG_RATIO=5;OVERCOMMIT=1;VFS_PRESSURE=50;MIN_FREE_KB=131072;RMEM_MAX=8388608;WMEM_MAX=8388608;TCP_RMEM="4096 16384 8388608";TCP_WMEM="4096 16384 8388608";SOMAXCONN=65535;BACKLOG=250000;SYN_BACKLOG=8192;PORT_RANGE="1024 65535";SCHED_AUTOGROUP=0;THP="never";NUMA=0;FIN_TIMEOUT=15;KEEPALIVE_TIME=300;KEEPALIVE_INTVL=30;KEEPALIVE_PROBES=5;UDP_RMEM_MIN=131072;GAME_EXTRA=$'net.ipv4.udp_rmem_min = 131072\nnet.ipv4.udp_wmem_min = 131072\nnet.core.optmem_max = 20480' ;;
        gateway) SWAPPINESS=10;DIRTY_RATIO=20;DIRTY_BG_RATIO=10;OVERCOMMIT=1;VFS_PRESSURE=50;MIN_FREE_KB=32768;RMEM_MAX=8388608;WMEM_MAX=8388608;TCP_RMEM="4096 16384 8388608";TCP_WMEM="4096 16384 8388608";SOMAXCONN=65535;BACKLOG=100000;SYN_BACKLOG=8192;PORT_RANGE="1024 65535";SCHED_AUTOGROUP=0;THP="never";NUMA=0;FIN_TIMEOUT=30;KEEPALIVE_TIME=300;KEEPALIVE_INTVL=30;KEEPALIVE_PROBES=5;UDP_RMEM_MIN=16384;GATEWAY_EXTRA=$'net.core.optmem_max = 20480' ;;
        balanced) SWAPPINESS=30;DIRTY_RATIO=20;DIRTY_BG_RATIO=10;OVERCOMMIT=0;VFS_PRESSURE=75;MIN_FREE_KB=32768;RMEM_MAX=16777216;WMEM_MAX=16777216;TCP_RMEM="4096 87380 16777216";TCP_WMEM="4096 65536 16777216";SOMAXCONN=4096;BACKLOG=5000;SYN_BACKLOG=4096;PORT_RANGE="32768 60999";SCHED_AUTOGROUP=0;THP="always";NUMA=1;FIN_TIMEOUT=30;KEEPALIVE_TIME=600;KEEPALIVE_INTVL=60;KEEPALIVE_PROBES=5;TCP_SLOW_START_AFTER_IDLE=1;BALANCED_EXTRA="vm.overcommit_memory = 0" ;;
        *) echo -e "${gl_red}错误: 未知场景${gl_bai}"; return 1 ;;
    esac
    local MEM_MB_VAL=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0) HAS_SWAP=$(free -m | awk '/Swap/{print $2}')
    if [ "$MEM_MB_VAL" -ge 16384 ]; then MIN_FREE_KB=131072; [ "$scene" != "balanced" ] && SWAPPINESS=5
    elif [ "$MEM_MB_VAL" -ge 4096 ]; then MIN_FREE_KB=65536
    elif [ "$MEM_MB_VAL" -ge 1024 ]; then MIN_FREE_KB=32768; if [ "$scene" != "balanced" ] && [ "$scene" != "game" ] && [ "$scene" != "gateway" ]; then RMEM_MAX=16777216; WMEM_MAX=16777216; TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"; fi
    else MIN_FREE_KB=16384;OVERCOMMIT=0;SWAPPINESS=10;RMEM_MAX=4194304;WMEM_MAX=4194304;SOMAXCONN=1024;BACKLOG=1000;TCP_RMEM="4096 32768 4194304";TCP_WMEM="4096 32768 4194304";HIGH_EXTRA="";WEB_EXTRA="";STREAM_EXTRA="";GAME_EXTRA="";BALANCED_EXTRA="";GATEWAY_EXTRA="";[ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; if [ "$HAS_SWAP" -gt 0 ]; then SWAPPINESS=60; echo -e "${gl_huang}极小内存(${MEM_MB_VAL}MB)，禁用zswap。${gl_bai}"; auto_setup_zram; else check_swap; auto_setup_zram; fi; fi
    local KVER=$(uname -r | grep -oP '^\d+\.\d+'); CC="cubic"; QDISC="fq_codel"
    if [ -n "$KVER" ] && { [ "$KVER" \> "4.9" ] || [ "$KVER" = "4.9" ]; }; then modprobe tcp_bbr 2>/dev/null; sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr && { CC="bbr"; QDISC="fq"; }; fi
    local TCP_MEM_MIN=$((MEM_MB_VAL * 256)) TCP_MEM_DEF=$((MEM_MB_VAL * 512)) TCP_MEM_MAX=$((MEM_MB_VAL * 1024))
    [ "$TCP_MEM_MIN" -lt 8192 ] && TCP_MEM_MIN=8192; [ "$TCP_MEM_DEF" -lt 16384 ] && TCP_MEM_DEF=16384; [ "$TCP_MEM_MAX" -lt 32768 ] && TCP_MEM_MAX=32768
    [ "$scene" = "stream" ] && [ "$MEM_MB_VAL" -ge 1024 ] && STREAM_EXTRA="${STREAM_EXTRA}"$'\nnet.ipv4.udp_mem = '"$((MEM_MB_VAL * 128)) $((MEM_MB_VAL * 256)) $((MEM_MB_VAL * 512))"
    local TW_BUCKETS=$((SOMAXCONN * 4)) MAX_ORPHANS=$((SOMAXCONN * 2)); [ "$scene" = "web" ] && [ "$MEM_MB_VAL" -ge 2048 ] && TW_BUCKETS=524288; [ "$TW_BUCKETS" -gt 524288 ] && TW_BUCKETS=524288; [ "$MAX_ORPHANS" -gt 131072 ] && MAX_ORPHANS=131072
    local backup_conf="${CONF}.bak.$(date +%s)"; [ -f "$CONF" ] && cp "$CONF" "$backup_conf"
    local lock_file="/tmp/99-yw-optimize.lock"; exec 200> "$lock_file"; flock -x 200
    echo -e "${gl_lv}写入优化配置...${gl_bai}"
    cat > "$CONF" << EOF
# YW 调优: $mode_name | 内存: ${MEM_MB_VAL}MB | $(date '+%Y-%m-%d %H:%M:%S')
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
 $( if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then echo "net.netfilter.nf_conntrack_max = $((SOMAXCONN * 32))"; echo "net.netfilter.nf_conntrack_tcp_timeout_established = 7200"; echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30"; echo "net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15"; echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15"; else echo "# conntrack 未启用"; fi )
 $HIGH_EXTRA
 $WEB_EXTRA
 $STREAM_EXTRA
 $GAME_EXTRA
 $BALANCED_EXTRA
 $GATEWAY_EXTRA
EOF
    flock -u 200; exec 200>&-
    echo -e "${gl_lv}应用优化参数...${gl_bai}"
    local total_params; total_params=$(grep -cE '^[a-z]' "$CONF" 2>/dev/null) || total_params=0
    local sysctl_output; sysctl_output=$(sysctl -p "$CONF" 2>&1)
    local error_params; error_params=$(echo "$sysctl_output" | grep -cE "Invalid argument|No such file or directory|unknown key" 2>/dev/null) || error_params=0
    echo -e "${gl_lv}已应用 $((total_params - error_params)) 项参数，跳过 ${error_params} 项不支持的参数${gl_bai}"
    if ! grep -q "# YW-optimize" /etc/security/limits.conf 2>/dev/null; then echo -e "\n# YW-optimize" >> /etc/security/limits.conf; echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" >> /etc/security/limits.conf; fi
    ulimit -n 1048576 2>/dev/null; check_swap >/dev/null 2>&1; bbr_on
    echo -e "${gl_lv}${mode_name} 优化完成！配置已持久化到 ${CONF}${gl_bai}"
    echo -e "${gl_lv}内存: ${MEM_MB_VAL}MB | 拥塞算法: ${CC} | 队列: ${QDISC}${gl_bai}"
    echo -e "${gl_lv}操作完成${gl_bai}"; echo ""; read -rs -n 1 -p "按任意键继续..."; echo ""
}

xanmod_add_repo() { local k="/usr/share/keyrings/xanmod-archive-keyring.gpg" l="/etc/apt/sources.list.d/xanmod-release.list" c=""; command -v lsb_release >/dev/null 2>&1 && c=$(lsb_release -sc) || { [ -r /etc/os-release ] && c=$(. /etc/os-release && echo "$VERSION_CODENAME"); }; if ! echo "bookworm trixie forky sid noble plucky" | grep -qw "$c"; then c="releases"; fi; if echo "jammy focal bullseye buster releases" | grep -qw "$c"; then echo -e "${gl_hong}XanMod 已停止支持${gl_bai}"; return 1; fi; [ -z "$c" ] && { echo "无法获取代号"; return 1; }; install wget gnupg ca-certificates || return 1; mkdir -p /usr/share/keyrings /etc/apt/sources.list.d; wget -qO - "https://dl.xanmod.org/archive.key" | gpg --dearmor -o "$k" --yes 2>/dev/null; chmod 644 "$k"; echo "deb [signed-by=$k] http://deb.xanmod.org $c main" > "$l"; }
xanmod_detect_package() { local p=$(awk 'BEGIN{ while(!/flags/) if(getline<"/proc/cpuinfo"!=1) exit 1; if(/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) l=1; if(l==1&&/cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) l=2; if(l==2&&/avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) l=3; if(l>0){print l;exit}}' /proc/cpuinfo 2>/dev/null) || return 1; [ "$p" -gt 3 ] && p=3; apt update -y >/dev/null 2>&1; for x in linux-xanmod linux-xanmod-lts; do local i="$p"; while [ "$i" -ge 1 ]; do local y="${x}-x64v${i}"; apt-cache policy "$y" 2>/dev/null | grep -q 'Candidate: [^ ]' && { printf '%s\n' "$y"; return 0; }; i=$((i-1)); done; done; return 1; }
bbrv3() { root_use; [ "$(uname -m)" = "aarch64" ] && { bash <(curl -sL jhb.ovh/jb/bbrv3arm.sh); return; }; [ -r /etc/os-release ] && . /etc/os-release; [ "$ID" != "debian" ] && [ "$ID" != "ubuntu" ] && { echo "仅支持Debian/Ubuntu"; return; }; if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then while true; do clear; echo "当前: $(uname -r)\n1.更新 2.卸载 0.返回"; read -e -p "选择: " c; case $c in 1) check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y --only-upgrade $(xanmod_detect_package) && bbr_on && server_reboot ;; 2) apt purge -y 'linux-*xanmod*' && apt autoremove -y && update-grub && rm -f /etc/apt/sources.list.d/xanmod-release.list && server_reboot ;; *) break ;; esac; done; else clear; echo "设置BBR3"; read -e -p "继续？: " c; [[ "$c" =~ ^[Yy]$ ]] && check_disk_space 3 && check_swap && xanmod_add_repo && apt update -y && apt install -y $(xanmod_detect_package) && bbr_on && server_reboot; fi; }
restore_defaults() { echo -e "${gl_lv}还原中...${gl_bai}"; rm -f /etc/sysctl.d/99-yw-optimize.conf /etc/sysctl.d/99-network-optimize.conf; sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null; sysctl --system >/dev/null 2>&1; [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; sed -i '/# YW-optimize/,+4d' /etc/security/limits.conf 2>/dev/null; [ -f /sys/module/zswap/parameters/enabled ] && echo N > /sys/module/zswap/parameters/enabled 2>/dev/null; sed -i '/vm.zswap.enabled/d' /etc/sysctl.conf 2>/dev/null; systemctl is-enabled zramswap >/dev/null 2>&1 && { systemctl stop zramswap >/dev/null 2>&1; systemctl disable zramswap >/dev/null 2>&1; }; echo -e "${gl_lv}已还原所有设置${gl_bai}"; read -rs -n 1 -p "按任意键继续..."; echo ""; }
verify_network_status() { clear; local r=$(sysctl -n net.core.rmem_max 2>/dev/null) m="未知"; case $r in 8388608) m="游戏/网关 (8MB)" ;; 16777216) m="中等内存 (16MB)" ;; 4194304) m="低内存保护 (4MB)" ;; 67108864|134217728) m="高性能/直播/网站 (64MB)" ;; esac; echo -e "${gl_huang}========================================\n       智能模式识别验证\n========================================${gl_bai}"; echo -e "算法: $(sysctl -n net.ipv4.tcp_congestion_control) | 队列: $(sysctl -n net.core.default_qdisc)"; echo -e "最大缓冲: $((r/1024/1024))MB | 鉴定: ${gl_lv}${m}${gl_bai}\n${gl_huang}========================================${gl_bai}"; }
show_sys_info() { while true; do local c=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"') m=$(awk '/MemTotal/{printf "%.0fMB", $2/1024/1024}' /proc/meminfo) l=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}') i=$(curl -4 -s --connect-timeout 2 ifconfig.me 2>/dev/null || echo "获取失败"); clear; echo -e "${gl_kjlan}==============${gl_bai}"; echo -e "${gl_kjlan}系统: ${gl_bai}${c} $(uname -r)"; echo -e "${gl_kjlan}内存: ${gl_bai}${m} | 负载: ${l}"; echo -e "${gl_kjlan}IP:   ${gl_bai}${i}"; echo -e "${gl_kjlan}==============${gl_bai}"; echo -e "${gl_huang}0. 返回"; read -e -p "选择: " m; case $m in 0|"") break ;; *) break ;; esac; done; }

Kernel_optimize() {
    root_use
    while true; do clear; local cur="未优化"; [ -f /etc/sysctl.d/99-yw-optimize.conf ] && cur=$(grep "^# YW 调优:" /etc/sysctl.d/99-yw-optimize.conf 2>/dev/null | sed 's/^# YW 调优: //' | awk '{print $1}')
    echo -e "${gl_lv}Linux系统内核参数优化${gl_bai}"; echo "------------------------------------------------"; echo -e "当前模式: ${gl_huang}${cur:-系统优化已启用}${gl_bai}"; echo -e "提供多种系统参数调优模式，用户可以根据自身使用场景进行选择切换。"; echo -e "${gl_huang}提示: ${gl_bai}生产环境请谨慎使用！"; echo -e "--------------------"; echo -e "1. 高性能优化模式：     极限IO聚簇写回，吞吐拉满"; echo -e "2. 均衡优化模式：       稳定至上，内存安全锁"; echo -e "3. 网站优化模式：       极限TW池，抗大促并发"; echo -e "4. 直播优化模式：       UDP极限拉爆+网卡软中断狂暴"; echo -e "5. 游戏服优化模式：     8MB电竞级TCP防Bufferbloat"; echo -e "6. 中转网关模式：       专精V2Ray/SS加密中转防卡顿 ${gl_huang}★${gl_bai}"; echo -e "7. 还原默认设置：       将系统设置还原为默认配置。"; echo -e "8. 自动调优：           根据测试数据自动调优内核参数。${gl_huang}★${gl_bai}"; echo -e "9. 释放内存缓存：      强制清理系统 Cache (谨慎使用)"; echo -e "10. 验证当前网络状态：  查看内核参数是否生效 ${gl_huang}★${gl_bai}"; echo "--------------------"; echo "0. 返回主菜单"; echo "--------------------"; read -e -p "请输入你的选择: " sub_choice
    case $sub_choice in 1) cd ~; clear; _kernel_optimize_core "高性能优化模式" "high" ;; 2) cd ~; clear; _kernel_optimize_core "均衡优化模式" "balanced" ;; 3) cd ~; clear; _kernel_optimize_core "网站优化模式" "web" ;; 4) cd ~; clear; _kernel_optimize_core "直播优化模式" "stream" ;; 5) cd ~; clear; _kernel_optimize_core "游戏服优化模式" "game" ;; 6) cd ~; clear; _kernel_optimize_core "中转网关模式" "gateway" ;; 7) cd ~; clear; restore_defaults ;; 8) echo -e "${gl_huang}即将拉取并执行远程网络优化脚本..."; read -e -p "按回车键继续，或按 Ctrl+C 取消: "; curl -sS ${gh_proxy}raw.githubusercontent.com/YW/sh/refs/heads/main/network-optimize.sh | bash ;; 9) echo -e "${gl_red}警告：强制释放内存缓存可能导致短暂 IO 抖动，生产环境请谨慎！${gl_bai}"; read -e -p "确定要执行 echo 3 > /proc/sys/vm/drop_caches 吗？: " drop_choice; if [[ "$drop_choice" =~ ^[Yy]$ ]]; then sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo -e "${gl_lv}✅ 内存缓存已释放${gl_bai}"; else echo "已取消"; fi; read -rs -n 1 -p "按任意键继续..." ;; 10) verify_network_status; read -rs -n 1 -p "按任意键返回菜单..." ;; 0|"") break ;; *) echo -e "${gl_red}无效的选择${gl_bai}" ; read -rs -n 1 -p "按任意键继续..." ;; esac; done
}

# ============================================================================
# 模块 5：Sing-Box 落地机节点管理面板
# ============================================================================
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="\033[36m"; B="\033[97m"
get_my_ip() { curl -4 -s -f --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s -f --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || echo "未知IP"; }
url_encode() { printf '%s' "$1" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g; s/ /%20/g; s/#/%23/g; s/?/%3F/g; s/&/%26/g; s/@/%40/g'; }
_test_tls_once() { local t1=$(date +%s%3N 2>/dev/null); timeout 2 openssl s_client -connect "${1}:443" -servername "${1}" </dev/null &>/dev/null && { local t2=$(date +%s%3N 2>/dev/null); local ms=$((t2 - t1)); [ "$ms" -ge 0 ] 2>/dev/null && echo "$ms" || echo "9999"; } || echo "9999"; }
select_sni() { echo -e "${Y}--- 伪装域名 (SNI) ---${R}" >&2; read -e -p "选择 (1默认 / 2优选 / 3手动): " c; case $c in 1) echo "www.microsoft.com" ;; 2) local d=(azure.microsoft.com bing.com www.icloud.com www.microsoft.com xp.apple.com www.xbox.com speed.cloudflare.com workers.cloudflare.com); local f="/tmp/sb_sni_test.$$"; : > "$f"; for i in "${d[@]}"; do echo "$(_test_tls_once "$i") $i" >> "$f"; done; local b_d="www.microsoft.com" b_t=9999; while IFS=' ' read -r t dom; do [ -n "$t" ] && [ "$t" -lt "$b_t" ] 2>/dev/null && { b_t=$t; b_d="$dom"; }; done < <(sort -n "$f"); rm -f "$f"; echo -e "${G}✅ 优选: ${b_d} (${b_t}ms)${R}" >&2; echo "$b_d" ;; 3) read -e -p "域名: " s; echo "${s:-www.microsoft.com}" ;; *) echo "www.microsoft.com" ;; esac; }
sb_check() { command -v sing-box >/dev/null 2>&1 || { echo -e "${RED}请先安装 Sing-Box 核心！${R}"; return 1; }; command -v jq >/dev/null 2>&1 || { echo -e "${RED}请先安装 jq！${R}"; return 1; }; }
sb_init_conf() { local c="/etc/sing-box/config.json"; [ -f "$c" ] && jq -e . "$c" >/dev/null 2>&1 || { mkdir -p /etc/sing-box; echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$c"; }; }
META_FILE="/etc/sing-box/.nodes_meta"
_init_meta_file() { [ ! -f "$META_FILE" ] || jq -e . "$META_FILE" >/dev/null 2>&1 || echo '{}' > "$META_FILE"; [ -f "$META_FILE" ] || { mkdir -p /etc/sing-box; echo '{}' > "$META_FILE"; }; }
_save_node_meta() { _init_meta_file; jq --arg p "$1" --arg n "$2" --arg t "$3" --arg pk "${4:-}" --arg ex "${5:-}" '.[$p] = {name: $n, type: $t, pub_key: $pk, extra: $ex}' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; }
_del_node_meta() { [ -f "$META_FILE" ] && jq --arg p "$1" 'del(.[$p])' "$META_FILE" > /tmp/sb_meta.json && mv /tmp/sb_meta.json "$META_FILE"; }
_get_node_meta() { [ -f "$META_FILE" ] && jq -r --arg p "$1" --arg f "$2" '.[$p][$f] // empty' "$META_FILE"; }
open_port() { local o=0 pr=$2; if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then ufw allow $1/$pr >/dev/null 2>&1 && o=1; elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-port=$1/$pr >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 && o=1; elif command -v iptables >/dev/null 2>&1; then iptables -C INPUT -p $pr --dport $1 -j ACCEPT >/dev/null 2>&1 && o=1 || { iptables -I INPUT -p $pr --dport $1 -j ACCEPT >/dev/null 2>&1 && o=1; }; fi; [ "$o" -eq 1 ] && echo -e "${G}  ✅ 放行 ${pr^^} $1${R}" || echo -e "${Y}  ⚠ 请手动放行 ${pr^^} $1${R}"; }
open_port_range() { local o=0 pr=${3:-udp}; if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then ufw allow $1:$2/$pr >/dev/null 2>&1 && o=1; elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then firewall-cmd --permanent --add-port=$1-$2/$pr >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1 && o=1; elif command -v iptables >/dev/null 2>&1; then iptables -C INPUT -p $pr --dport $1:$2 -j ACCEPT >/dev/null 2>&1 && o=1 || { iptables -I INPUT -p $pr --dport $1:$2 -j ACCEPT >/dev/null 2>&1 && o=1; }; fi; [ "$o" -eq 1 ] && echo -e "${G}  ✅ 放行 ${pr^^} $1-$2${R}" || echo -e "${Y}  ⚠ 请手动放行 ${pr^^} $1-$2${R}"; }

sb_manage_menu() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || [ ! -s "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then sb_init_conf; systemctl stop sing-box >/dev/null 2>&1; fi
    while true; do clear; local sb_status="${RED}未安装${R}"; if command -v sing-box >/dev/null 2>&1; then if jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1; then systemctl is-active --quiet sing-box 2>/dev/null && sb_status="${G}运行中 ✅${R}" || sb_status="${Y}已停止${R}"; else sb_status="${Y}待配置 (无节点)${R}"; fi; fi
    echo -e "${G}========================================${R}"; echo -e "${G}       Sing-Box 落地节点管理          ${R}"; echo -e "${G}========================================${R}"; echo -e "核心状态: ${sb_status}${R}"; echo -e "${G}----------------------------------------${R}"
    echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
    echo -e "${G}2.${R} 添加 VLESS Reality 节点 (含优选SNI)"
    echo -e "${G}3.${R} 添加 Hysteria2 节点 (支持端口跳跃) ${H}★${R}"
    echo -e "${G}4.${R} 添加 VLESS+WebSocket 节点 (TLS) ${H}★${R}"
    echo -e "${H}5.${R} 查看节点与链接"
    echo -e "${RED}6.${R} 删除节点 (按端口)"
    echo -e "${H}7.${R} 重启/停止/查看日志"
    echo -e "${Y}8.${R} 手动开放端口 (防火墙放行)"
    echo -e "${G}========================================${R}"; echo -e "${H}0.${R} 返回主菜单"; echo -e "${G}========================================${R}"
    read -e -p "请输入选择: " c; case $c in
        1) echo -e "${C}正在连接官方源安装...${R}"; if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash; elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash; fi; read -rs -n 1 -p "按任意键继续..." ;;
        2) sb_add_reality ;; 3) sb_add_hy2 ;; 4) sb_add_vless_ws ;; 5) sb_view_nodes ;; 6) sb_del_node ;;
        7) echo -e "${C}1.重启 2.停止 3.日志:${R}"; read -e -p "选择: " a; case $a in 1) systemctl restart sing-box && echo -e "${G}已重启${R}" ;; 2) systemctl stop sing-box && echo -e "${Y}已停止${R}" ;; 3) journalctl -u sing-box -n 30 --no-pager ;; esac; read -rs -n 1 -p "按任意键继续..." ;;
        8) read -e -p "端口: " mp; [[ "$mp" =~ ^[0-9]+$ ]] && { open_port "$mp" tcp; open_port "$mp" udp; } || echo -e "${RED}无效${R}"; read -rs -n 1 -p "按任意键继续..." ;;
        0|"") break ;; *) echo -e "${RED}输入无效${R}"; sleep 1 ;; esac; done
}

sb_add_vless_ws() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }; echo -e "${C}--- 添加 VLESS+WebSocket 落地节点 ---${R}"
    read -e -p "监听端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}端口错误${R}"; read -rs -n 1 -p ""; return; }
    local dp=$(openssl rand -hex 4); read -e -p "WS 路径 (回车默认 /${dp}): " ws_path; ws_path="${ws_path:-/$(openssl rand -hex 4)}"; [[ "$ws_path" != /* ]] && ws_path="/${ws_path}"
    local sni; sni=$(select_sni); echo -e "${Y}生成 UUID 和证书...${R}"; local uuid=$(cat /proc/sys/kernel/random/uuid) crt="/etc/sing-box/ws_${port}.crt" key="/etc/sing-box/ws_${port}.key"
    [ ! -f "$crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=$sni" -days 3650 2>/dev/null; chmod 600 "$key" 2>/dev/null
    local dn="VLESS-WS-${port}"; read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    local ij; ij=$(jq -n --argjson p "$port" --arg u "$uuid" --arg s "$sni" --arg path "$ws_path" --arg c "$crt" --arg k "$key" '{type:"vless",tag:("vless-ws-"+($p|tostring)),listen:"::",listen_port:$p,users:[{uuid:$u}],tls:{enabled:true,server_name:$s,certificate_path:$c,key_path:$k},transport:{type:"ws",path:$path}}')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then echo -e "${Y}防火墙放行...${R}"; open_port "$port" "tcp"; _save_node_meta "$port" "$nn" "vless-ws" "" "$ws_path"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 10 --no-pager; mv "${conf}.bak."* "$conf" 2>/dev/null; rm -f "$crt" "$key"; _del_node_meta "$port"; read -rs -n 1 -p ""; return; fi
        local ip=$(get_my_ip); echo -e "${G}✅ VLESS+WS 添加成功！${R}\n${Y}链接:${R}\n${B}vless://${uuid}@${ip}:${port}?encryption=none&security=tls&type=ws&host=$(url_encode "$sni")&path=$(url_encode "$ws_path")&sni=$(url_encode "$sni")&allowInsecure=1#$(url_encode "$nn")${R}"
    else echo -e "${RED}校验失败！${R}"; mv "${conf}.bak."* "$conf" 2>/dev/null; rm -f "$crt" "$key"; fi; read -rs -n 1 -p "按任意键继续..."
}

sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }; echo -e "${C}--- 添加 VLESS Reality 落地节点 ---${R}"
    read -e -p "端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}端口错误${R}"; read -rs -n 1 -p ""; return; }
    local sni; sni=$(select_sni); echo -e "${Y}生成密钥对...${R}"; local uuid=$(cat /proc/sys/kernel/random/uuid) keys=$(sing-box generate reality-keypair 2>/dev/null) pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}') pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
    [ -z "$pub" ] && { echo -e "${RED}生成失败${R}"; read -rs -n 1 -p ""; return; }
    local dn="Reality-${port}"; read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    jq --argjson p "$port" --arg u "$uuid" --arg k "$pk" --arg s "$sni" '.inbounds += [{"type":"vless","tag":"vless-in-\($p)","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$k}}}]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then echo -e "${Y}防火墙放行...${R}"; open_port "$port" "tcp"; _save_node_meta "$port" "$nn" "vless" "$pub"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 10 --no-pager; mv "${conf}.bak."* "$conf" 2>/dev/null; _del_node_meta "$port"; read -rs -n 1 -p ""; return; fi
        local ip=$(get_my_ip); echo -e "${G}✅ Reality 添加成功！${R}\n${Y}链接:${R}\n${B}vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=$(url_encode "$pub")&type=tcp#$(url_encode "$nn")${R}"
    else echo -e "${RED}校验失败！${R}"; mv "${conf}.bak."* "$conf" 2>/dev/null; fi; read -rs -n 1 -p "按任意键继续..."
}

sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 Hysteria2 落地节点 ---${R}"; read -e -p "端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}端口错误${R}"; read -rs -n 1 -p ""; return; }
    local hop=""
    read -e -p "开启端口跳跃？: " eh; if [[ "$eh" =~ ^[Yy]$ ]]; then read -e -p "起始端口: " hs; read -e -p "结束端口: " he; [[ "$hs" =~ ^[0-9]+$ && "$he" =~ ^[0-9]+$ && "$he" -gt "$hs" ]] && hop="$hs-$he" || echo -e "${Y}范围无效，跳过跳跃。${R}"; fi
    local sni; sni=$(select_sni); echo -e "${Y}生成密码和证书...${R}"; local pass=$(openssl rand -base64 16) crt="/etc/sing-box/hy2_${port}.crt" key="/etc/sing-box/hy2_${port}.key"
    [ ! -f "$crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=$sni" -days 3650 2>/dev/null; chmod 600 "$key" 2>/dev/null
    local dn="Hy2-${port}"; read -e -p "节点名称 (回车默认 ${dn}): " nn; [ -z "$nn" ] && nn="$dn"
    sb_init_conf; local conf="/etc/sing-box/config.json"; cp "$conf" "${conf}.bak.$(date +%s)"
    local ij; ij=$(jq -n --argjson p "$port" --arg pw "$pass" --arg s "$sni" --arg c "$crt" --arg k "$key" --arg h "$hop" '{type:"hysteria2",tag:("hy2-in-"+($p|tostring)),listen:"::",listen_port:$p,users:[{password:$pw}],tls:{enabled:true,server_name:$s,certificate_path:$c,key_path:$k}} | if $h != "" then . + {ports: $h} else . end')
    jq --argjson inb "$ij" '.inbounds += [$inb]' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then echo -e "${Y}防火墙放行...${R}"; open_port "$port" "udp"; [ -n "$hop" ] && open_port_range "${hop%-*}" "${hop#*-}" "udp"; _save_node_meta "$port" "$nn" "hysteria2" "" "$hop"; systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then echo -e "${RED}❌ 启动失败！${R}"; journalctl -u sing-box -n 10 --no-pager; mv "${conf}.bak."* "$conf" 2>/dev/null; rm -f "$crt" "$key"; _del_node_meta "$port"; read -rs -n 1 -p ""; return; fi
        local ip=$(get_my_ip) link="hysteria2://$(url_encode "$pass")@${ip}:${port}?insecure=1&sni=${sni}"; [ -n "$hop" ] && link="${link}&ports=${hop}"; link="${link}#$(url_encode "$nn")"
        echo -e "${G}✅ Hysteria2 添加成功！${R}\n${Y}链接:${R}\n${B}${link}${R}\n${H}注意: 请确保云安全组已放行 UDP ${port} ${hop}${R}"
    else echo -e "${RED}校验失败！${R}"; mv "${conf}.bak."* "$conf" 2>/dev/null; rm -f "$crt" "$key"; fi; read -rs -n 1 -p "按任意键继续..."
}

sb_view_nodes() {
    local conf="/etc/sing-box/config.json"; jq -e '.inbounds | length > 0' "$conf" >/dev/null 2>&1 || { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    local ip=$(get_my_ip); echo -e "${G}========================================${R}\n${G}           当前节点列表              ${R}\n${G}========================================${R}"
    while IFS= read -r in; do
        local port=$(echo "$in" | jq -r '.listen_port') type=$(_get_node_meta "$port" "type") name=$(_get_node_meta "$port" "name"); [ -z "$name" ] && name="未命名"
        local extra=$(_get_node_meta "$port" "extra") en=$(url_encode "$name")
        if [ "$type" = "vless-ws" ]; then local u=$(echo "$in" | jq -r '.users[0].uuid') s=$(echo "$in" | jq -r '.tls.server_name'); echo -e "${Y}[$type] $name (端口: $port)${R}"; echo -e "${B}vless://${u}@${ip}:${port}?encryption=none&security=tls&type=ws&host=$(url_encode "$s")&path=$(url_encode "$extra")&sni=$(url_encode "$s")&allowInsecure=1#${en}${R}"
        elif [ "$type" = "vless" ]; then local u=$(echo "$in" | jq -r '.users[0].uuid') s=$(echo "$in" | jq -r '.tls.server_name') pk=$(_get_node_meta "$port" "pub_key"); echo -e "${Y}[$type] $name (端口: $port)${R}"; echo -e "${B}vless://${u}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${s}&fp=chrome&pbk=$(url_encode "$pk")&type=tcp#${en}${R}"
        elif [ "$type" = "hysteria2" ]; then local p=$(echo "$in" | jq -r '.users[0].password') s=$(echo "$in" | jq -r '.tls.server_name') lk="hysteria2://$(url_encode "$p")@${ip}:${port}?insecure=1&sni=${s}"; [ -n "$extra" ] && { lk="${lk}&ports=${extra}"; echo -e "${Y}[$type] $name (端口: $port | 跳跃: $extra)${R}"; } || echo -e "${Y}[$type] $name (端口: $port)${R}"; echo -e "${B}${lk}#${en}${R}"; fi
        echo "----------------------------------------"
    done < <(jq -c '.inbounds[]' "$conf"); read -rs -n 1 -p "按任意键继续..."
}

sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }; local conf="/etc/sing-box/config.json" ports=$(jq -r '.inbounds[].listen_port' "$conf" 2>/dev/null)
    [ -z "$ports" ] && { echo -e "${Y}无节点${R}"; read -rs -n 1 -p ""; return; }
    echo -e "${Y}当前端口:${R}"; echo "$ports" | awk '{print " - "$0}'; read -e -p "输入要删除的端口: " dp
    echo "$ports" | grep -qw "$dp" || { echo -e "${RED}不存在${R}"; read -rs -n 1 -p ""; return; }
    local nt=$(_get_node_meta "$dp" "type"); cp "$conf" "${conf}.bak.$(date +%s)"; jq --argjson p "$dp" 'del(.inbounds[] | select(.listen_port == $p))' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    if sing-box check -c "$conf" >/dev/null 2>&1; then [ "$nt" = "hysteria2" ] && rm -f "/etc/sing-box/hy2_${dp}.*"; [ "$nt" = "vless-ws" ] && rm -f "/etc/sing-box/ws_${dp}.*"; _del_node_meta "$dp"; systemctl restart sing-box; echo -e "${G}✅ 已删除${R}"; else echo -e "${RED}失败，回滚${R}"; mv "${conf}.bak."* "$conf" 2>/dev/null; fi; read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# YW 系统优化与管理面板 - 主入口
# ============================================================================
main_menu() {
    while true; do clear
    echo -e "${G}========================================${gl_bai}"
    echo -e "${G}    YW 系统优化与管理面板              ${gl_bai}"
    echo -e "${G}========================================${gl_bai}"
    echo -e "${C}1.${gl_bai} 系统信息查询"
    echo -e "${C}2.${gl_bai} 安装 BBRv3 内核"
    echo -e "${C}3.${gl_bai} Linux系统内核参数优化"
    echo -e "${C}4.${gl_bai} Sing-Box 落地节点管理"
    echo -e "${C}5.${gl_bai} 管理虚拟内存"
    echo -e "${G}========================================${gl_bai}"
    echo -e "${H}0.${gl_bai} 退出脚本"
    echo -e "${G}========================================${gl_bai}"
    read -e -p "请输入选择: " main_choice
    case $main_choice in 1) show_sys_info ;; 2) bbrv3 ;; 3) Kernel_optimize ;; 4) sb_manage_menu ;; 5) change_swap_size ;; 0|"") exit 0 ;; *) echo -e "${gl_red}输入无效${gl_bai}"; sleep 1 ;; esac; done
}

# ★ 启动逻辑：先查ROOT -> 再装环境 -> 最后进面板
root_use
check_env
main_menu
