#!/bin/bash

# ============================================================================
# Linux 内核调优模块（独立运行修复版）
# 统一核心函数 + 场景差异化参数 + 持久化到配置文件 + 硬件自适应
# ============================================================================

# 颜色变量定义
gl_lv="\033[32m"    # 绿色
gl_bai="\033[37m"   # 白色
gl_cheng="\033[33m" # 橙色/黄色
gl_hong="\033[31m"  # 红色

# 获取内存大小（MB）
_get_mem_mb() {
	awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

# 统一内核调优核心函数
_kernel_optimize_core() {
	local mode_name="$1"
	local scene="${2:-high}"
	local CONF="/etc/sysctl.d/99-kejilion-optimize.conf"
	local RC_LOCAL="/etc/rc.local"
	local MEM_MB=$(_get_mem_mb)

	echo -e "${gl_lv}正在切换到 ${mode_name} 模式...${gl_bai}"

	# ── 根据场景设定参数 ──
	local SWAPPINESS DIRTY_RATIO DIRTY_BG_RATIO OVERCOMMIT MIN_FREE_KB VFS_PRESSURE
	local RMEM_MAX WMEM_MAX TCP_RMEM TCP_WMEM
	local SOMAXCONN BACKLOG SYN_BACKLOG
	local PORT_RANGE SCHED_AUTOGROUP THP NUMA FIN_TIMEOUT
	local KEEPALIVE_TIME KEEPALIVE_INTVL KEEPALIVE_PROBES

	case "$scene" in
		high|stream|game)
			SWAPPINESS=10; DIRTY_RATIO=15; DIRTY_BG_RATIO=5; OVERCOMMIT=1; VFS_PRESSURE=50
			RMEM_MAX=67108864; WMEM_MAX=67108864
			TCP_RMEM="4096 262144 67108864"; TCP_WMEM="4096 262144 67108864"
			SOMAXCONN=8192; BACKLOG=250000; SYN_BACKLOG=8192; PORT_RANGE="1024 65535"
			SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=10
			KEEPALIVE_TIME=300; KEEPALIVE_INTVL=30; KEEPALIVE_PROBES=5
			;;
		web)
			SWAPPINESS=10; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=1; VFS_PRESSURE=50
			RMEM_MAX=33554432; WMEM_MAX=33554432
			TCP_RMEM="4096 131072 33554432"; TCP_WMEM="4096 131072 33554432"
			SOMAXCONN=16384; BACKLOG=10000; SYN_BACKLOG=16384; PORT_RANGE="1024 65535"
			SCHED_AUTOGROUP=0; THP="never"; NUMA=0; FIN_TIMEOUT=15
			KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
			;;
		balanced)
			SWAPPINESS=30; DIRTY_RATIO=20; DIRTY_BG_RATIO=10; OVERCOMMIT=0; VFS_PRESSURE=75
			RMEM_MAX=16777216; WMEM_MAX=16777216
			TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
			SOMAXCONN=4096; BACKLOG=5000; SYN_BACKLOG=4096; PORT_RANGE="1024 49151"
			SCHED_AUTOGROUP=1; THP="always"; NUMA=1; FIN_TIMEOUT=30
			KEEPALIVE_TIME=600; KEEPALIVE_INTVL=60; KEEPALIVE_PROBES=5
			;;
	esac

	# ── 根据内存大小自适应调整 ──
	if [ "$MEM_MB" -ge 16384 ]; then
		MIN_FREE_KB=131072
		[ "$scene" != "balanced" ] && SWAPPINESS=5
	elif [ "$MEM_MB" -ge 4096 ]; then
		MIN_FREE_KB=65536
	elif [ "$MEM_MB" -ge 1024 ]; then
		MIN_FREE_KB=32768
		if [ "$scene" != "balanced" ] && [ "$scene" != "web" ]; then
			RMEM_MAX=16777216; WMEM_MAX=16777216
			TCP_RMEM="4096 87380 16777216"; TCP_WMEM="4096 65536 16777216"
		fi
	else
		MIN_FREE_KB=16384; SWAPPINESS=30; OVERCOMMIT=0
		RMEM_MAX=4194304; WMEM_MAX=4194304
		TCP_RMEM="4096 32768 4194304"; TCP_WMEM="4096 32768 4194304"
		SOMAXCONN=1024; BACKLOG=1000; SYN_BACKLOG=1024
	fi

	# ── 场景特定附加参数 ──
	local EXTRA_CONFIG=""
	if [ "$scene" = "stream" ]; then
		EXTRA_CONFIG="\n# 直播推流 UDP 优化\nnet.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.tcp_notsent_lowat = 16384"
	elif [ "$scene" = "game" ]; then
		EXTRA_CONFIG="\n# 游戏服低延迟优化\nnet.ipv4.udp_rmem_min = 16384\nnet.ipv4.udp_wmem_min = 16384\nnet.ipv4.tcp_notsent_lowat = 16384\nnet.ipv4.tcp_slow_start_after_idle = 0"
	fi

	# ── 加载 BBR 模块 ──
	local CC="bbr"
	local QDISC="fq"
	local KVER
	KVER=$(uname -r | grep -oP '^\d+\.\d+')
	if printf '%s\n%s' "4.9" "$KVER" | sort -V -C; then
		if ! lsmod 2>/dev/null | grep -q tcp_bbr; then modprobe tcp_bbr 2>/dev/null; fi
		if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
			CC="cubic"; QDISC="fq_codel"
		fi
	else
		CC="cubic"; QDISC="fq_codel"
	fi

	# ── 备份已有配置 ──
	[ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"

	# ── 计算 tcp_mem ──
	local PAGE_SIZE=4
	local TOTAL_PAGES=$((MEM_MB * 1024 / PAGE_SIZE))
	local TCP_MEM_MIN=$((TOTAL_PAGES / 8))
	local TCP_MEM_PRESSURE=$((TOTAL_PAGES / 4))
	local TCP_MEM_MAX=$((TOTAL_PAGES / 2))

	# ── 写入配置文件 ──
	echo -e "${gl_lv}写入 sysctl 优化配置...${gl_bai}"
	cat > "$CONF" << SYSCTL
# kejilion 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

net.core.default_qdisc = $QDISC
net.ipv4.tcp_congestion_control = $CC

net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $WMEM_MAX
net.core.rmem_default = $(echo "$TCP_RMEM" | awk '{print $2}')
net.core.wmem_default = $(echo "$TCP_WMEM" | awk '{print $2}')
net.ipv4.tcp_rmem = $TCP_RMEM
net.ipv4.tcp_wmem = $TCP_WMEM

net.core.somaxconn = $SOMAXCONN
net.core.netdev_max_backlog = $BACKLOG
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG

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

net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX
net.ipv4.tcp_max_orphans = 32768${EXTRA_CONFIG}
SYSCTL

	# ── 立即生效 ──
	sysctl --system >/dev/null 2>&1

	# ── 运行时动态参数切换 ──
	echo -e "${gl_lv}配置内核运行时参数...${gl_bai}"
	[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo "$SCHED_AUTOGROUP" > /sys/kernel/debug/sched/autogroup_enabled
	[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
	[ -f /proc/sys/vm/numa_zonelist_order ] && sysctl -w vm.numa_zonelist_order=$( [ "$NUMA" -eq 1 ] && echo "Node" || echo "Default" ) >/dev/null 2>&1

	# ── 持久化到 rc.local ──
	if [ -f "$RC_LOCAL" ]; then sed -i '/# BEGIN KEJILION RUNTIME/,/# END KEJILION RUNTIME/d' "$RC_LOCAL"; fi
	if [ "$scene" != "balanced" ]; then
		[ ! -f "$RC_LOCAL" ] && echo -e '#!/bin/sh -e\nexit 0' > "$RC_LOCAL" && chmod +x "$RC_LOCAL"
		sed -i '/^exit 0/i # BEGIN KEJILION RUNTIME\n[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo '"$SCHED_AUTOGROUP"' > /sys/kernel/debug/sched/autogroup_enabled\n[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo '"$THP"' > /sys/kernel/mm/transparent_hugepage/enabled\n# END KEJILION RUNTIME' "$RC_LOCAL"
	fi

	echo -e "${gl_cheng}内核优化配置成功！已应用并开启持久化。${gl_bai}"
}

# 外层对接函数
optimize_high_performance() { _kernel_optimize_core "高性能模式" "high"; }
optimize_balanced() { _kernel_optimize_core "均衡模式" "balanced"; }
optimize_web_server() { _kernel_optimize_core "网站服务器模式" "web"; }
optimize_stream_server() { _kernel_optimize_core "直播推流模式" "stream"; }
optimize_game_server() { _kernel_optimize_core "游戏低延迟模式" "game"; }

# 还原函数
restore_defaults() {
	local CONF="/etc/sysctl.d/99-kejilion-optimize.conf"
	local RC_LOCAL="/etc/rc.local"
	echo -e "${gl_lv}正在恢复系统默认内核参数...${gl_bai}"
	if [ -f "$CONF" ]; then rm -f "$CONF"; sysctl --system >/dev/null 2>&1; fi
	[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo "1" > /sys/kernel/debug/sched/autogroup_enabled
	[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "always" > /sys/kernel/mm/transparent_hugepage/enabled
	if [ -f "$RC_LOCAL" ]; then sed -i '/# BEGIN KEJILION RUNTIME/,/# END KEJILION RUNTIME/d' "$RC_LOCAL"; fi
	echo -e "${gl_cheng}内核参数已成功恢复至系统默认状态！${gl_bai}"
}

# ============================================================================
# ⚙️ 核心修复：执行分发层与控制台菜单（使命令调用起作用）
# ============================================================================

# 必须使用 root 权限运行
if [ "$EUID" -ne 0 ]; then
	echo -e "${gl_hong}错误：请使用 root 用户或 sudo 运行此脚本。${gl_bai}"
	exit 1
fi

# 判断输入参数（支持非交互式调用：如命令后带参数 high/web/balanced/restore 等）
case "$1" in
	high) optimize_high_performance; exit 0 ;;
	balanced) optimize_balanced; exit 0 ;;
	web) optimize_web_server; exit 0 ;;
	stream) optimize_stream_server; exit 0 ;;
	game) optimize_game_server; exit 0 ;;
	restore) restore_defaults; exit 0 ;;
	"") # 如果没有任何参数，则弹出可交互菜单
		clear
		echo -e "${gl_lv}============================================${gl_bai}"
		echo -e "${gl_cheng}      kejilion 智能内核调优控制台        ${gl_bai}"
		echo -e "${gl_lv}============================================${gl_bai}"
		echo -e " 1. 切换到 [高性能模式] (密集计算/压测)"
		echo -e " 2. 切换到 [网站服务器模式] (高并发连接)"
		echo -e " 3. 切换到 [均衡模式] (轻量虚拟机/日常优化)"
		echo -e " 4. 切换到 [直播推流模式] (UDP专项低延迟)"
		echo -e " 5. 切换到 [游戏服务器模式] (关闭空闲慢启动)"
		echo -e " 6. 恢复 [系统默认配置] (彻底还原清理)"
		echo -e " 0. 退出脚本"
		echo -e "${gl_lv}============================================${gl_bai}"
		read -p "请输入对应的数字 [0-6]: " menu_choice

		case "$menu_choice" in
			1) optimize_high_performance ;;
			2) optimize_web_server ;;
			3) optimize_balanced ;;
			4) optimize_stream_server ;;
			5) optimize_game_server ;;
			6) restore_defaults ;;
			*) echo -e "${gl_cheng}已退出。${gl_bai}"; exit 0 ;;
		esac
		;;
	*)
		echo -e "${gl_hong}未知参数: $1${gl_bai}"
		echo -e "可用参数：high | balanced | web | stream | game | restore"
		exit 1
		;;
esac
