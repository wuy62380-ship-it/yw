#!/bin/bash

# ============================================================================
# Linux 内核调优模块（增强重构版）
# 统一核心函数 + 场景差异化参数 + 持久化到配置文件 + 硬件自适应
# ============================================================================

# 颜色变量定义（请根据你原脚本的全局变量自行调整）
gl_lv="\033[32m"    # 绿色
gl_bai="\033[37m"   # 白色
gl_cheng="\033[33m" # 橙色/黄色

# 获取内存大小（MB）
_get_mem_mb() {
	awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo
}

# 统一内核调优核心函数
# 参数: $1 = 模式名称, $2 = 场景 (high/balanced/web/stream/game)
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
			# 高性能/直播/游戏：激进参数
			SWAPPINESS=10
			DIRTY_RATIO=15
			DIRTY_BG_RATIO=5
			OVERCOMMIT=1
			VFS_PRESSURE=50
			RMEM_MAX=67108864
			WMEM_MAX=67108864
			TCP_RMEM="4096 262144 67108864"
			TCP_WMEM="4096 262144 67108864"
			SOMAXCONN=8192
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
			;;
		web)
			# 网站服务器：高并发优先
			SWAPPINESS=10
			DIRTY_RATIO=20
			DIRTY_BG_RATIO=10
			OVERCOMMIT=1
			VFS_PRESSURE=50
			RMEM_MAX=33554432
			WMEM_MAX=33554432
			TCP_RMEM="4096 131072 33554432"
			TCP_WMEM="4096 131072 33554432"
			SOMAXCONN=16384
			BACKLOG=10000
			SYN_BACKLOG=16384
			PORT_RANGE="1024 65535"
			SCHED_AUTOGROUP=0
			THP="never"
			NUMA=0
			FIN_TIMEOUT=15
			KEEPALIVE_TIME=600
			KEEPALIVE_INTVL=60
			KEEPALIVE_PROBES=5
			;;
		balanced)
			# 均衡模式：适度优化
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
		# 小内存缩小缓冲区
		if [ "$scene" != "balanced" ] && [ "$scene" != "web" ]; then
			RMEM_MAX=16777216
			WMEM_MAX=16777216
			TCP_RMEM="4096 87380 16777216"
			TCP_WMEM="4096 65536 16777216"
		fi
	else
		# 极其严苛的超小内存环境（1GB以下机型自适应）
		MIN_FREE_KB=16384
		SWAPPINESS=30
		OVERCOMMIT=0
		RMEM_MAX=4194304
		WMEM_MAX=4194304
		TCP_RMEM="4096 32768 4194304"
		TCP_WMEM="4096 32768 4194304"
		SOMAXCONN=1024
		BACKLOG=1000
		SYN_BACKLOG=1024
	fi

	# ── 直播场景额外：UDP 缓冲区加大 ──
	local STREAM_EXTRA=""
	if [ "$scene" = "stream" ]; then
		STREAM_EXTRA="
# 直播推流 UDP 优化
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384"
	fi

	# ── 游戏服场景额外：低延迟优先 ──
	local GAME_EXTRA=""
	if [ "$scene" = "game" ]; then
		GAME_EXTRA="
# 游戏服低延迟优化
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0"
	fi

	# ── 加载 BBR 模块 ──
	local CC="bbr"
	local QDISC="fq"
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

	# ── 备份已有配置 ──
	[ -f "$CONF" ] && cp "$CONF" "${CONF}.bak.$(date +%s)"

	# ── 计算适用于 Page 单元的 tcp_mem (标准1页为4KB) ──
	local PAGE_SIZE=4
	local TOTAL_PAGES=$((MEM_MB * 1024 / PAGE_SIZE))
	local TCP_MEM_MIN=$((TOTAL_PAGES / 8))
	local TCP_MEM_PRESSURE=$((TOTAL_PAGES / 4))
	local TCP_MEM_MAX=$((TOTAL_PAGES / 2))

	# ── 写入 sysctl 配置文件（持久化） ──
	echo -e "${gl_lv}写入 sysctl 优化配置...${gl_bai}"
	cat > "$CONF" << SYSCTL
# kejilion 内核调优配置
# 模式: $mode_name | 场景: $scene
# 内存: ${MEM_MB}MB | 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# ── 内存与虚拟内存 ──
vm.swappiness = $SWAPPINESS
vm.dirty_ratio = $DIRTY_RATIO
vm.dirty_background_ratio = $DIRTY_BG_RATIO
vm.overcommit_memory = $OVERCOMMIT
vm.min_free_kbytes = $MIN_FREE_KB
vm.vfs_cache_pressure = $VFS_PRESSURE

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

# ── 端口与内存 ──
net.ipv4.ip_local_port_range = $PORT_RANGE
net.ipv4.tcp_mem = $TCP_MEM_MIN $TCP_MEM_PRESSURE $TCP_MEM_MAX
net.ipv4.tcp_max_orphans = 32768
${STREAM_EXTRA}${GAME_EXTRA}
SYSCTL

	# ── 使 sysctl 配置立即生效 ──
	sysctl --system >/dev/null 2>&1

	# ── 处理无法通过 sysctl 设置的系统运行时参数 (THP/NUMA/Sched) ──
	echo -e "${gl_lv}配置内核运行时参数...${gl_bai}"
	
	# 1. 动态调节当前运行状态
	[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo "$SCHED_AUTOGROUP" > /sys/kernel/debug/sched/autogroup_enabled
	[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
	[ -f /proc/sys/vm/numa_zonelist_order ] && sysctl -w vm.numa_zonelist_order=$( [ "$NUMA" -eq 1 ] && echo "Node" || echo "Default" ) >/dev/null 2>&1

	# 2. 移除 rc.local 中旧的 kejilion 标记条目
	if [ -f "$RC_LOCAL" ]; then
		sed -i '/# BEGIN KEJILION RUNTIME/,/# END KEJILION RUNTIME/d' "$RC_LOCAL"
	fi

	# 3. 将运行时参数持久化到 rc.local
	if [ "$scene" != "balanced" ]; then
		[ ! -f "$RC_LOCAL" ] && echo -e '#!/bin/sh -e\nexit 0' > "$RC_LOCAL" && chmod +x "$RC_LOCAL"
		sed -i '/^exit 0/i # BEGIN KEJILION RUNTIME\n[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo '"$SCHED_AUTOGROUP"' > /sys/kernel/debug/sched/autogroup_enabled\n[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo '"$THP"' > /sys/kernel/mm/transparent_hugepage/enabled\n# END KEJILION RUNTIME' "$RC_LOCAL"
	fi

	echo -e "${gl_cheng}内核优化配置成功！已应用并开启持久化。${gl_bai}"
}

# ============================================================================
# 外层对接函数（替换原有旧函数入口）
# ============================================================================

optimize_high_performance() {
	_kernel_optimize_core "高性能模式" "high"
}

optimize_balanced() {
	_kernel_optimize_core "均衡模式" "balanced"
}

optimize_web_server() {
	_kernel_optimize_core "网站服务器模式" "web"
}

optimize_stream_server() {
	_kernel_optimize_core "直播推流模式" "stream"
}

optimize_game_server() {
	_kernel_optimize_core "游戏低延迟模式" "game"
}

# ============================================================================
# 恢复默认配置函数
# ============================================================================
restore_defaults() {
	local CONF="/etc/sysctl.d/99-kejilion-optimize.conf"
	local RC_LOCAL="/etc/rc.local"

	echo -e "${gl_lv}正在恢复系统默认内核参数...${gl_bai}"

	# 移除 sysctl 自定义配置文件
	if [ -f "$CONF" ]; then
		rm -f "$CONF"
		# 强制重载全部默认配置
		sysctl --system >/dev/null 2>&1
	fi

	# 恢复 THP 和 调度组 默认内核行为
	[ -f /sys/kernel/debug/sched/autogroup_enabled ] && echo "1" > /sys/kernel/debug/sched/autogroup_enabled
	[ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "always" > /sys/kernel/mm/transparent_hugepage/enabled

	# 清理 rc.local
	if [ -f "$RC_LOCAL" ]; then
		sed -i '/# BEGIN KEJILION RUNTIME/,/# END KEJILION RUNTIME/d' "$RC_LOCAL"
	fi

	echo -e "${gl_cheng}内核参数已成功恢复至系统默认状态！${gl_bai}"
}
