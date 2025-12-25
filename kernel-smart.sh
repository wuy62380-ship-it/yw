#!/bin/bash
# ============================================================
#  YW / Devi 智能内核切换 + BBR 自动启用 + 直播链路优化（v2.1）
#  适配所有 VPS：官方内核 / cloud 内核 / grub / 无 grub / Direct Kernel Boot
#  Debian 11 / 12 / 13
# ============================================================

set -e

echo "============================================================"
echo "  YW 智能内核切换 + BBR 自动启用 + 直播优化（v2.1）"
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
# 1. 检查是否为 Direct Kernel Boot
# ============================================================
log_step "检测是否为 Direct Kernel Boot"

if [ ! -f "/boot/vmlinuz-$CURRENT_KERNEL" ]; then
    log_warn "当前运行内核不在 /boot 中 → 可能是 Direct Kernel Boot"
    if ! ls /boot | grep -q vmlinuz; then
        log_err "此 VPS 使用宿主机强制内核（Direct Kernel Boot），无法切换内核，也无法启用 BBR"
    fi
fi

log_ok "未发现 Direct Kernel Boot 阻断，可继续"

# ============================================================
# 2. 如果 available 列表里有 bbr → 直接启用 BBR（无需切内核）
# ============================================================
if echo "$AVAILABLE_CC" | grep -qw bbr; then
    log_step "当前内核具备 BBR 能力 → 直接启用 BBR（无需切换内核）"

    mkdir -p /etc/modules-load.d
    echo "tcp_bbr" > /etc/modules-load.d/zz-bbr.conf
    modprobe tcp_bbr 2>/dev/null || true

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/100-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    # ============================================================
    # 集成直播链路专用 sysctl（激进版）
    # ============================================================
    log_step "应用直播链路专用 sysctl 优化（激进版）"

    cat > /etc/sysctl.d/200-live-stream.conf <<EOF
# ============================================================
#  YW / Devi 直播链路专用 sysctl（激进版）
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

    sysctl --system

    CURRENT_CC2=$(sysctl net.ipv4.tcp_congestion_control | awk -F'= ' '{print $2}')
    if [ "$CURRENT_CC2" = "bbr" ]; then
        log_ok "BBR + 直播链路优化 已成功启用并永久生效"
        echo
        echo "============================================================"
        echo "  结论：当前内核已成功启用 BBR（通常为 BBR v2）"
        echo "  已应用直播链路优化参数（激进版）"
        echo "  无需切换内核，脚本已完成全部操作"
        echo "============================================================"
        echo
        exit 0
    else
        log_warn "尝试启用 BBR 后仍为：$CURRENT_CC2 → 将尝试切换官方内核"
    fi
fi

# ============================================================
# 3. available 不含 bbr → 尝试安装官方内核
# ============================================================
log_step "当前内核不具备 BBR → 尝试安装 Debian 官方内核"

apt update
apt install -y linux-image-amd64

log_ok "官方内核安装完成"

# ============================================================
# 4. 查找官方内核（非 cloud 内核）
# ============================================================
log_step "查找官方内核（非 cloud 内核）"

OFFICIAL_KERNEL=$(ls /boot | grep vmlinuz | grep -v cloud | head -n 1 | sed 's/vmlinuz-//')

if [ -z "$OFFICIAL_KERNEL" ]; then
    log_err "未找到官方内核（非 cloud 内核），无法切换内核 → 此 VPS 无法启用 BBR"
fi

log_ok "找到官方内核：$OFFICIAL_KERNEL"

# ============================================================
# 5. 检查 grub 是否存在
# ============================================================
log_step "检测 grub 状态"

if [ ! -d /boot/grub ] && [ ! -d /boot/grub2 ]; then
    log_err "未检测到 grub → 此 VPS 无法切换内核 → 无法启用 BBR"
fi

log_ok "grub 存在，可切换内核"

# ============================================================
# 6. 强制 grub 使用官方内核
# ============================================================
log_step "强制 grub 使用官方内核"

MENU_ENTRY="Debian GNU/Linux, with Linux $OFFICIAL_KERNEL"

grub-set-default "$MENU_ENTRY" || log_warn "grub-set-default 执行失败"
update-grub

log_ok "已设置 grub 默认启动项为：$MENU_ENTRY"

# ============================================================
# 7. 重启后自动启用 BBR + 直播优化
# ============================================================
log_step "设置重启后自动启用 BBR + 直播优化"

cat > /root/run-bbr-after-reboot.sh <<EOF
#!/bin/bash

mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/zz-bbr.conf
modprobe tcp_bbr 2>/dev/null || true

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/100-bbr.conf <<EOT
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOT

cat > /etc/sysctl.d/200-live-stream.conf <<EOT
# 直播链路专用 sysctl（激进版）
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
EOT

sysctl --system
rm -f /root/run-bbr-after-reboot.sh
EOF

chmod +x /root/run-bbr-after-reboot.sh

cat > /etc/systemd/system/run-bbr-after-reboot.service <<EOF
[Unit]
Description=Enable BBR + Live Stream Optimization after reboot
After=network.target

[Service]
Type=oneshot
ExecStart=/root/run-bbr-after-reboot.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable run-bbr-after-reboot.service

log_ok "已创建自动启用 BBR + 直播优化的 systemd 服务"

# ============================================================
# 8. 自动重启
# ============================================================
echo
echo "============================================================"
echo "  所有步骤已完成，系统将在 3 秒后自动重启"
echo "============================================================"
echo

sleep 3
reboot
