#!/bin/bash
# ============================================================
#  Devi 专属：Debian x86_64 BBRplus‑R2 一键安装脚本（最终可用版）
# ============================================================

set -e

echo "============================================================"
echo "  BBRplus‑R2 内核自动安装（x86_64 / Debian）"
echo "============================================================"
echo

if [ "$(id -u)" != "0" ]; then
    echo "[错误] 请使用 root 运行"
    exit 1
fi

echo "[步骤] 获取最新 BBRplus‑R2 版本..."

# 直接解析 Releases 页面（因为 API 不提供 .deb）
URLS=$(curl -s https://github.com/ylx2016/bbrplus-r2-kernel/releases \
    | grep -o "https://github.com/ylx2016/bbrplus-r2-kernel/releases/download/[^\"]*amd64.deb")

if [ -z "$URLS" ]; then
    echo "[错误] 未找到可用的 amd64 BBRplus‑R2 内核包"
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

echo "[步骤] 写入 sysctl 配置..."
sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/default_qdisc/d' /etc/sysctl.conf
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbrplus-r2" >> /etc/sysctl.conf
sysctl -p
echo "[OK] sysctl 配置完成"
echo

echo "============================================================"
echo "  BBRplus‑R2 内核已安装"
echo "  请重启系统以加载新内核："
echo
echo "      reboot"
echo
echo "  重启后验证："
echo
echo "      sysctl net.ipv4.tcp_congestion_control"
echo "      lsmod | grep -E \"bbr|bbrplus\""
echo "============================================================"
