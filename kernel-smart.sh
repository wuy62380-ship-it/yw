#!/bin/bash
# ============================================================
#  YW 专属：智能内核切换脚本（安全模式）
#  Debian 11 / 12 / 13 · 自动检测内核 · 自动安装官方内核（BBR v2）
#  重启后自动执行 auto-bbr.sh
# ============================================================

set -e

echo "============================================================"
echo "  YW 智能内核切换脚本（安全模式）"
echo "============================================================"
echo

log_step() {
    echo
    echo "---------------- [步骤] $1 ----------------"
}

log_info() {
    echo "[信息] $1"
}

log_warn() {
    echo "[警告] $1"
}

log_ok() {
    echo "[OK] $1"
}

# -------------------------------
# 检查 root
# -------------------------------
if [ "$(id -u)" != "0" ]; then
    log_err "请使用 root 运行"
    exit 1
fi

# -------------------------------
# 检查系统版本
# -------------------------------
if [ ! -f /etc/os-release ]; then
    log_err "无法检测系统版本：缺少 /etc/os-release"
    exit 1
fi

VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2)
NAME=$(grep ^NAME= /etc/os-release | cut -d '"' -f 2)

log_info "检测到系统：$NAME"
log_info "检测到 Debian 版本：$VERSION"

if [ "$NAME" != "Debian GNU/Linux" ] && [ "$NAME" != "Debian" ]; then
    log_warn "当前系统不是 Debian，脚本仅支持 Debian 11 / 12 / 13"
fi

if [ "$VERSION" != "11" ] && [ "$VERSION" != "12" ] && [ "$VERSION" != "13" ]; then
    log_err "本脚本仅支持 Debian 11 / 12 / 13"
    exit 1
fi

# -------------------------------
# 检查当前内核是否支持 BBR
# -------------------------------
log_step "检测当前内核是否支持 BBR"

KCFG="/boot/config-$(uname -r)"
SUPPORT_BBR="否"

if [ -f "$KCFG" ]; then
    if grep -qi "CONFIG_TCP_CONG_BBR=y" "$KCFG"; then
        SUPPORT_BBR="是"
    fi
else
    log_warn "未找到 $KCFG，无法从配置文件判断内核支持情况"
fi

log_info "当前内核支持 BBR：$SUPPORT_BBR"

if [ "$SUPPORT_BBR" = "是" ]; then
    log_ok "当前内核已支持 BBR，无需切换内核"
    echo
    echo "你可以直接运行 auto-bbr.sh："
    echo "  wget -N --no-check-certificate \"https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/auto-bbr.sh\" && chmod +x auto-bbr.sh && ./auto-bbr.sh"
    exit 0
fi

log_warn "当前内核不支持 BBR，将自动安装 Debian 官方原版内核（支持 BBR v2）"

# -------------------------------
# 安装 Debian 官方内核
# -------------------------------
log_step "安装 Debian 官方原版内核（支持 BBR v2）"

apt update
apt install linux-image-amd64 -y

log_ok "官方内核安装完成"

# -------------------------------
# 更新 grub
# -------------------------------
log_step "更新 grub 引导配置"

update-grub

log_ok "grub 更新完成"

# -------------------------------
# 设置开机自动运行 auto-bbr.sh
# -------------------------------
log_step "设置重启后自动运行 auto-bbr.sh"

cat > /root/run-bbr-after-reboot.sh <<EOF
#!/bin/bash
wget -N --no-check-certificate "https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/auto-bbr.sh"
chmod +x auto-bbr.sh
./auto-bbr.sh
rm -f /root/run-bbr-after-reboot.sh
EOF

chmod +x /root/run-bbr-after-reboot.sh

# 写入 systemd 服务
cat > /etc/systemd/system/run-bbr-after-reboot.service <<EOF
[Unit]
Description=Run auto-bbr.sh after reboot
After=network.target

[Service]
Type=oneshot
ExecStart=/root/run-bbr-after-reboot.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable run-bbr-after-reboot.service

log_ok "已创建 systemd 服务：run-bbr-after-reboot.service"

# -------------------------------
# 最终提示
# -------------------------------
echo
echo "============================================================"
echo "  内核切换准备完成"
echo "------------------------------------------------------------"
echo "  已安装 Debian 官方原版内核（支持 BBR v2）"
echo "  已设置默认内核"
echo "  重启后将自动运行 auto-bbr.sh 完成 BBR 优化"
echo "------------------------------------------------------------"
echo "  请现在执行：reboot"
echo "============================================================"
echo
