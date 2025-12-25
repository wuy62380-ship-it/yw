#!/bin/bash
# ============================================================
#  YW / Devi auto-bbr.sh v2.1
#  功能：在当前内核上启用 BBR + 直播链路专用 sysctl（激进版）
#  适配：Debian 11 / 12 / 13，BBRv1 / BBRv2，中转机 / 落地机 / 推流机
# ============================================================

set -e

echo "============================================================"
echo "  YW auto-bbr.sh v2.1"
echo "  启用 BBR + 直播链路优化（激进版）"
echo "============================================================"
echo

log_step() { echo -e "\n---------------- [步骤] $1 ----------------"; }
log_info() { echo "[信息] $1"; }
log_warn() { echo "[警告] $1"; }
log_ok()   { echo "[OK] $1"; }
log_err()  { echo "[错误] $1"; exit 1; }

# ============================================================
# 0. 基础信息
# ============================================================
CURRENT_KERNEL=$(uname -r)
AVAILABLE_CC=$(sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | awk -F'= ' '{print $2}')

log_info "当前运行内核：$CURRENT_KERNEL"
log_info "可用拥塞算法：$AVAILABLE_CC"

# ============================================================
# 1. 检查内核是否具备 BBR 能力
# ============================================================
log_step "检测当前内核是否具备 BBR 能力"

if echo "$AVAILABLE_CC" | grep -qw bbr; then
    log_ok "当前内核支持 BBR，将继续进行配置"
else
    log_err "当前内核的可用算法列表中不包含 bbr，此内核不支持 BBR，无法继续优化"
fi

# ============================================================
# 2. 启用 BBR 模块
# ============================================================
log_step "加载 BBR 模块并设置开机自加载"

mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/zz-bbr.conf
modprobe tcp_bbr 2>/dev/null || true

log_ok "BBR 模块已处理（如内核支持会成功加载）"

# ============================================================
# 3. 写入基础 BBR 配置（100-bbr.conf）
# ============================================================
log_step "写入基础 BBR 配置（100-bbr.conf）"

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/100-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

log_ok "基础 BBR 配置已写入 /etc/sysctl.d/100-bbr.conf"

# ============================================================
# 4. 写入直播链路专用 sysctl（激进版，200-live-stream.conf）
# ============================================================
log_step "写入直播链路专用 sysctl（激进版，200-live-stream.conf）"

cat > /etc/sysctl.d/200-live-stream.conf <<EOF
# ============================================================
#  YW / Devi 直播链路专用 sysctl（激进版）
#  适用：推流机 / 中转机 / 落地机 / 跨境链路
# ============================================================

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_mtu_probing = 1

net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0

net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 10

net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
EOF

log_ok "直播链路 sysctl 配置已写入 /etc/sysctl.d/200-live-stream.conf"

# ============================================================
# 5. 应用所有 sysctl 配置
# ============================================================
log_step "应用所有 sysctl 配置（sysctl --system）"

sysctl --system

CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control | awk -F'= ' '{print $2}')

if [ "$CURRENT_CC" = "bbr" ]; then
    log_ok "当前拥塞控制算法已为：bbr"
else
    log_warn "当前拥塞控制算法仍为：$CURRENT_CC（理论上应为 bbr，请检查内核支持情况）"
fi

# ============================================================
# 6. 最终总结
# ============================================================
echo
echo "============================================================"
echo "  auto-bbr.sh v2.1 执行完成"
echo "------------------------------------------------------------"
echo "  当前内核：$CURRENT_KERNEL"
echo "  可用算法：$AVAILABLE_CC"
echo "  当前算法：$CURRENT_CC"
echo "------------------------------------------------------------"
echo "  已启用：BBR + 直播链路专用 sysctl（激进版）"
echo "  适用于：推流机 / 中转机 / 落地机 / 跨境直播"
echo "============================================================"
echo
