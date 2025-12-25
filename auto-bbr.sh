#!/bin/bash
# ============================================================
#  YW 专属：Debian 11–13 自动 BBR + 直播优化脚本（最终版）
# ============================================================

set -e

echo "============================================================"
echo "  Debian 11–13 自动 BBR + 直播优化脚本"
echo "============================================================"
echo

# -------------------------------
# 检查 root
# -------------------------------
if [ "$(id -u)" != "0" ]; then
    echo "[错误] 请使用 root 运行"
    exit 1
fi

# -------------------------------
# 检查 Debian 版本
# -------------------------------
VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2)

echo "[信息] 检测到 Debian 版本：$VERSION"
echo

# ============================================================
# Debian 11：自动安装 BBRplus‑R2 内核
# ============================================================
if [ "$VERSION" = "11" ]; then
    echo "[步骤] Debian 11 检测到，开始自动安装 BBRplus‑R2 内核"
    echo

    # 获取内核包
    echo "[步骤] 获取 BBRplus‑R2 内核包列表..."
    URLS=$(curl -s https://github.com/ylx2016/bbrplus-r2-kernel/releases \
        | grep -o "https://github.com/ylx2016/bbrplus-r2-kernel/releases/download/[^\"]*amd64.deb")

    if [ -z "$URLS" ]; then
        echo "[错误] 未找到 BBRplus‑R2 内核包"
        exit 1
    fi

    echo "[OK] 找到以下内核包："
    echo "$URLS"
    echo

    echo "[步骤] 下载内核包..."
    for url in $URLS; do
        wget -q --show-progress "$url"
    done
    echo "[OK] 下载完成"
    echo

    echo "[步骤] 安装内核..."
    dpkg -i linux-image-*-bbrplus-r2_amd64.deb || apt --fix-broken install -y
    dpkg -i linux-headers-*-bbrplus-r2_amd64.deb || true
    echo "[OK] 内核安装完成"
    echo

    echo "[步骤] 更新 grub..."
    update-grub
    echo "[OK] grub 更新完成"
    echo

    TARGET_ALGO="bbrplus-r2"
fi

# ============================================================
# Debian 12 / 13：启用 BBR v2
# ============================================================
if [ "$VERSION" = "12" ] || [ "$VERSION" = "13" ]; then
    echo "[步骤] Debian $VERSION 检测到，启用 BBR v2（最稳定）"
    echo
    TARGET_ALGO="bbr"
fi

# ============================================================
# 写入直播专用 sysctl 优化
# ============================================================
echo "[步骤] 写入直播专用 sysctl 优化..."

# 清理旧参数
sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/default_qdisc/d' /etc/sysctl.conf
sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_rmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_wmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_notsent_lowat/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_max_syn_backlog/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syncookies/d' /etc/sysctl.conf

# 写入新参数
cat >> /etc/sysctl.conf <<EOF
# ================== YW 直播专用优化 ==================
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$TARGET_ALGO

# 直播推流缓冲区优化
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# 降低直播卡顿
net.ipv4.tcp_notsent_lowat=131072

# 提高弱网抗丢包能力
net.ipv4.tcp_fastopen=3

# 提高连接稳定性
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_syncookies=1
# =======================================================
EOF

sysctl -p
echo "[OK] sysctl 优化完成"
echo

# ============================================================
# 完成提示
# ============================================================
echo "============================================================"
echo "  已启用：$TARGET_ALGO + 直播专用优化"
echo
echo "验证："
echo "  sysctl net.ipv4.tcp_congestion_control"
echo "  lsmod | grep -E \"bbr|bbrplus\""
echo
if [ "$VERSION" = "11" ]; then
    echo "Debian 11：请重启以加载 BBRplus‑R2 内核："
    echo "  reboot"
fi
echo "============================================================"
