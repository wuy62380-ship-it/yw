#!/bin/bash
# ============================================================
#  YW / Devi 智能内核切换脚本（安全模式）
#  Debian 11 / 12 / 13 · 自动检测内核 · 自动安装官方内核（BBR v2）
#  自动检测是否支持内核切换 · 自动强制 grub 使用官方内核
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

log_err() {
    echo "[错误] $1"
    exit 1
}

# ============================================================
# 自动检测 VPS 是否支持内核切换
# ============================================================
log_step "检测 VPS 是否支持内核切换"

SUPPORT_KERNEL_SWITCH="yes"

# 1. 检查 grub 是否存在
if [ ! -d /boot/grub ] && [ ! -d /boot/grub2 ]; then
    log_warn "未检测到 grub 引导目录，可能使用宿主机内核"
    SUPPORT_KERNEL_SWITCH="no"
fi

# 2. 检查 /boot 内核是否被实际使用
CURRENT_KERNEL=$(uname -r)
if [ ! -f "/boot/vmlinuz-$CURRENT_KERNEL" ]; then
    log_warn "当前运行内核不在 /boot 中，说明系统未使用本地内核"
    SUPPORT_KERNEL_SWITCH="no"
fi

# 3. 检查是否使用 Direct Kernel Boot
if dmesg | grep -qi "Direct kernel boot"; then
    log_err "检测到 Direct Kernel Boot：宿主机强制加载内核，无法切换内核"
    SUPPORT_KERNEL_SWITCH="no"
fi

# 4. 检查 cloud 内核特征
if uname -r | grep -qi "cloud"; then
    log_warn "当前内核为 cloud 内核，通常无法切换为自定义内核"
fi

# 最终判断
if [ "$SUPPORT_KERNEL_SWITCH" = "no" ]; then
    echo
    echo "============================================================"
    echo "  ❌ 检测结果：此 VPS 不支持内核切换"
    echo "------------------------------------------------------------"
    echo "  原因：系统未使用 grub / 使用 Direct Kernel Boot / 使用 cloud 内核"
    echo "  结论：无法启用 BBR / BBR v2 / BBRplus / BBRplus-R2"
    echo "------------------------------------------------------------"
    echo "  建议：更换支持自定义内核的 KVM VPS"
    echo "============================================================"
    exit 1
else
    log_ok "检测通过：此 VPS 支持内核切换，可继续执行"
fi

# ============================================================
# 检查系统版本
# ============================================================
if [ ! -f /etc/os-release ]; then
    log_err "无法检测系统版本：缺少 /etc/os-release"
fi

VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2)
NAME=$(grep ^NAME= /etc/os-release | cut -d '"' -f 2)

log_info "检测到系统：$NAME"
log_info "检测到 Debian 版本：$VERSION"

if [ "$VERSION" != "11" ] && [ "$VERSION" != "12" ] && [ "$VERSION" != "13" ]; then
    log_err "本脚本仅支持 Debian 11 / 12 / 13"
fi

# ============================================================
# 检查当前内核是否支持 BBR
# ============================================================
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

# ============================================================
# 安装 Debian 官方内核
# ============================================================
log_step "安装 Debian 官方原版内核（支持 BBR v2）"

apt update
apt install linux-image-amd64 -y

log_ok "官方内核安装完成"

# ============================================================
# 强制 grub 使用官方内核启动
# ============================================================
log_step "强制 grub 使用官方内核启动"

OFFICIAL_KERNEL=$(ls /boot | grep vmlinuz | grep -v cloud | head -n 1 | sed 's/vmlinuz-//')

if [ -z "$OFFICIAL_KERNEL" ]; then
    log_err "未找到官方内核（非 cloud 内核），无法强制设置 grub 默认启动项"
fi

MENU_ENTRY="Debian GNU/Linux, with Linux $OFFICIAL_KERNEL"

log_info "检测到官方内核：$OFFICIAL_KERNEL"
log_info "设置 grub 默认启动项为：$MENU_ENTRY"

grub-set-default "$MENU_ENTRY" || log_warn "grub-set-default 执行失败，请稍后手动检查"

update-grub

log_ok "已强制设置 grub 默认启动项为官方内核"

# ============================================================
# 设置重启后自动运行 auto-bbr.sh
# ============================================================
log_step "设置重启后自动运行 auto-bbr.sh"

cat > /root/run-bbr-after-reboot.sh <<EOF
#!/bin/bash
wget -N --no-check-certificate "https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/auto-bbr.sh"
chmod +x auto-bbr.sh
./auto-bbr.sh
rm -f /root/run-bbr-after-reboot.sh
EOF

chmod +x /root/run-bbr-after-reboot.sh

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

# ============================================================
# 最终提示
# ============================================================
echo
echo "============================================================"
echo "  内核切换准备完成"
echo "------------------------------------------------------------"
echo "  已安装 Debian 官方原版内核（支持 BBR v2）"
echo "  已强制设置 grub 默认启动项为官方内核"
echo "  重启后将自动运行 auto-bbr.sh 完成 BBR 优化"
echo "------------------------------------------------------------"
echo "  请现在执行：reboot"
echo "============================================================"
echo
