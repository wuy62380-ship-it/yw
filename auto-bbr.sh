#!/bin/bash
# ============================================================
#  YW 专属：Debian 11–13 自动 BBR + 直播优化 + 智能检测脚本
#  用途：跨境直播 / 推流 优先，激进策略（bbrplus-r2 → bbrplus → bbr → cubic）
# ============================================================

set -e

echo "============================================================"
echo "  Debian 11–13 自动 BBR + 直播优化 + 智能检测脚本"
echo "============================================================"
echo

# -------------------------------
# 函数：打印标题行
# -------------------------------
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

log_err() {
    echo "[错误] $1"
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
# 检查 Debian 版本
# -------------------------------
if [ ! -f /etc/os-release ]; then
    log_err "无法检测系统版本：缺少 /etc/os-release"
    exit 1
fi

VERSION=$(grep VERSION_ID /etc/os-release | cut -d '"' -f 2)
NAME=$(grep ^NAME= /etc/os-release | cut -d '"' -f 2)

log_info "检测到系统：$NAME"
log_info "检测到 Debian 版本：$VERSION"
echo

if [ "$NAME" != "Debian GNU/Linux" ] && [ "$NAME" != "Debian" ]; then
    log_warn "当前系统不是 Debian，脚本仅针对 Debian 11 / 12 / 13 设计"
fi

# 记录目标算法（后面智能检测也会用）
TARGET_ALGO=""
NEED_REBOOT="否"

# ============================================================
# Debian 11：自动安装 BBRplus‑R2 内核（如失败将由智能检测模块处理）
# ============================================================
if [ "$VERSION" = "11" ]; then
    log_step "Debian 11 检测到，尝试自动安装 BBRplus‑R2 内核"

    # 获取内核包
    log_step "获取 BBRplus‑R2 内核包列表..."
    URLS=$(curl -s https://github.com/ylx2016/bbrplus-r2-kernel/releases \
        | grep -o "https://github.com/ylx2016/bbrplus-r2-kernel/releases/download/[^\"]*amd64.deb" || true)

    if [ -z "$URLS" ]; then
        log_err "未找到 BBRplus‑R2 内核包，后续将由智能检测模块处理 fallback"
    else
        log_ok "找到以下内核包："
        echo "$URLS"
        echo

        log_step "下载内核包..."
        for url in $URLS; do
            log_info "下载：$url"
            wget -q --show-progress "$url"
        done
        log_ok "内核包下载完成"

        log_step "安装内核..."
        dpkg -i linux-image-*-bbrplus-r2_amd64.deb || apt --fix-broken install -y
        dpkg -i linux-headers-*-bbrplus-r2_amd64.deb || true
        log_ok "内核安装完成"

        log_step "更新 grub..."
        update-grub
        log_ok "grub 更新完成"

        TARGET_ALGO="bbrplus-r2"
        NEED_REBOOT="是"
    fi
fi

# ============================================================
# Debian 12 / 13：默认启用 BBR（v2/官方实现）
# ============================================================
if [ "$VERSION" = "12" ] || [ "$VERSION" = "13" ]; then
    log_step "Debian $VERSION 检测到，设置目标算法为 BBR（官方实现，内核自带 BBR v2）"
    TARGET_ALGO="bbr"
fi

# 如果版本不是 11/12/13，则直接退出
if [ "$VERSION" != "11" ] && [ "$VERSION" != "12" ] && [ "$VERSION" != "13" ]; then
    log_err "本脚本仅支持 Debian 11 / 12 / 13，当前版本为：$VERSION"
    exit 1
fi

# 如果此时 TARGET_ALGO 仍为空，默认用 bbr，后续智能检测会自动处理 fallback
if [ -z "$TARGET_ALGO" ]; then
    log_warn "未显式设置目标算法，默认使用 bbr，智能检测模块将自动处理"
    TARGET_ALGO="bbr"
fi

# ============================================================
# 写入直播专用 sysctl 优化（先清理旧参数，再写入新参数）
# ============================================================
log_step "写入直播专用 sysctl 优化"

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
# ================== YW 直播专用优化结束 ==================
EOF

sysctl -p >/dev/null 2>&1 || true
log_ok "sysctl 优化写入完成（已尝试加载）"

# ============================================================
# 智能检测 + 自动修复 + 自动 fallback（激进优先 F1）
# 放在脚本末尾统一执行
# ============================================================
log_step "智能检测当前算法生效情况"

CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [ -z "$CURRENT_ALGO" ]; then
    CURRENT_ALGO="未知"
fi
log_info "当前内核报告的拥塞算法：$CURRENT_ALGO"
log_info "目标算法：$TARGET_ALGO"

# -------------------------------
# 检测虚拟化环境
# -------------------------------
log_step "检测虚拟化环境"
VIRT="unknown"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT=$(systemd-detect-virt)
else
    VIRT="unknown"
fi
log_info "当前虚拟化环境：$VIRT"

UNSUPPORTED_VIRT="否"
if [ "$VIRT" = "openvz" ] || [ "$VIRT" = "lxc" ] || [ "$VIRT" = "docker" ]; then
    log_warn "当前可能为容器虚拟化环境（$VIRT），某些拥塞算法可能不受支持"
    UNSUPPORTED_VIRT="是"
fi

# -------------------------------
# 检查内核配置中是否支持相关算法
# -------------------------------
log_step "检测当前内核支持的拥塞算法（从 /boot/config 中分析）"

KERNEL_CFG="/boot/config-$(uname -r)"
SUPPORT_BBR="否"
SUPPORT_BBRPLUS="否"
SUPPORT_BBRPLUS_R2="否"

if [ -f "$KERNEL_CFG" ]; then
    if grep -qi "CONFIG_TCP_CONG_BBR=y" "$KERNEL_CFG"; then
        SUPPORT_BBR="是"
    fi
    if grep -qi "CONFIG_TCP_CONG_BBRPLUS=y" "$KERNEL_CFG"; then
        SUPPORT_BBRPLUS="是"
    fi
    if grep -qi "CONFIG_TCP_CONG_BBRPLUS_R2=y" "$KERNEL_CFG"; then
        SUPPORT_BBRPLUS_R2="是"
    fi
else
    log_warn "未找到 $KERNEL_CFG，无法从配置文件判断内核支持情况，将仅根据实际生效结果处理"
fi

log_info "内核支持 BBR：$SUPPORT_BBR"
log_info "内核支持 BBRplus：$SUPPORT_BBRPLUS"
log_info "内核支持 BBRplus-R2：$SUPPORT_BBRPLUS_R2"

# -------------------------------
# 检查模块是否加载
# -------------------------------
log_step "检测内核模块加载状态"

LSMOD_BBR=$(lsmod | grep -E "bbr|bbrplus" || true)
if [ -n "$LSMOD_BBR" ]; then
    log_info "检测到以下 BBR/BBRplus 相关模块："
    echo "$LSMOD_BBR"
else
    log_warn "未检测到 BBR/BBRplus 相关模块（某些内核为内建，无模块也可能正常）"
fi

# -------------------------------
# 智能修复 + fallback 逻辑（激进优先 F1）
# Debian 11：bbrplus-r2 → bbrplus → bbr → cubic
# Debian 12/13：bbr → cubic
# -------------------------------

log_step "应用智能修复 + fallback 策略（激进优先 F1）"

FINAL_ALGO=""

if [ "$UNSUPPORTED_VIRT" = "是" ]; then
    log_warn "虚拟化环境可能不支持高级拥塞算法，将优先保证稳定性"
fi

if [ "$VERSION" = "11" ]; then
    log_info "当前为 Debian 11，使用激进优先链路：bbrplus-r2 → bbrplus → bbr → cubic"

    if [ "$SUPPORT_BBRPLUS_R2" = "是" ] && [ "$UNSUPPORTED_VIRT" = "否" ]; then
        FINAL_ALGO="bbrplus-r2"
        log_ok "选择 bbrplus-r2 作为最终算法（内核支持，适合跨境直播）"
    elif [ "$SUPPORT_BBRPLUS" = "是" ] && [ "$UNSUPPORTED_VIRT" = "否" ]; then
        FINAL_ALGO="bbrplus"
        log_ok "bbrplus-r2 不可用，fallback 到 bbrplus"
    elif [ "$SUPPORT_BBR" = "是" ]; then
        FINAL_ALGO="bbr"
        log_ok "bbrplus 系列不可用或不适合，fallback 到 bbr（官方实现）"
    else
        FINAL_ALGO="cubic"
        log_warn "内核不支持 BBR 系列，fallback 到 cubic（默认算法，稳定优先）"
    fi
else
    log_info "当前为 Debian $VERSION，bbrplus 系列内核不可用，仅使用：bbr → cubic"

    if [ "$SUPPORT_BBR" = "是" ] && [ "$UNSUPPORTED_VIRT" = "否" ]; then
        FINAL_ALGO="bbr"
        log_ok "选择 bbr 作为最终算法（内核支持，适合直播）"
    else
        FINAL_ALGO="cubic"
        log_warn "内核不支持 BBR 或虚拟化限制，fallback 到 cubic（稳定优先）"
    fi
fi

# -------------------------------
# 如果 FINAL_ALGO 与当前内核报告不一致，则尝试修复
# -------------------------------
log_step "对比目标算法与当前生效算法"

log_info "智能决策后的最终算法应为：$FINAL_ALGO"
log_info "当前内核报告的算法：$CURRENT_ALGO"

if [ "$FINAL_ALGO" != "$CURRENT_ALGO" ]; then
    log_warn "当前算法与智能决策不一致，尝试自动修复..."

    sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=$FINAL_ALGO" >> /etc/sysctl.conf

    sysctl net.ipv4.tcp_congestion_control="$FINAL_ALGO" >/dev/null 2>&1 || true

    CURRENT_ALGO_AFTER=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    if [ -z "$CURRENT_ALGO_AFTER" ]; then
        CURRENT_ALGO_AFTER="未知"
    fi

    log_info "修复后内核报告的算法：$CURRENT_ALGO_AFTER"

    if [ "$CURRENT_ALGO_AFTER" != "$FINAL_ALGO" ]; then
        log_warn "自动修复后仍未成功应用 $FINAL_ALGO，可能需要重启或当前内核不支持"
        NEED_REBOOT="是"
    else
        log_ok "已成功将算法修复为：$FINAL_ALGO"
    fi
else
    log_ok "当前算法已与智能决策一致，无需修复"
fi

# 最终再读取一次当前算法
CURRENT_ALGO=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
if [ -z "$CURRENT_ALGO" ]; then
    CURRENT_ALGO="未知"
fi

# ============================================================
# 总结输出
# ============================================================
echo
echo "============================================================"
echo "  YW 直播专用智能 BBR 配置完成（详细状态）"
echo "------------------------------------------------------------"
echo "  系统版本          ：Debian $VERSION"
echo "  虚拟化环境        ：$VIRT"
echo "  内核支持 BBR      ：$SUPPORT_BBR"
echo "  内核支持 BBRplus  ：$SUPPORT_BBRPLUS"
echo "  内核支持 BBRplus-R2：$SUPPORT_BBRPLUS_R2"
echo "------------------------------------------------------------"
echo "  目标算法（初始）  ：$TARGET_ALGO"
echo "  智能决策最终算法  ：$FINAL_ALGO"
echo "  当前内核实际算法  ：$CURRENT_ALGO"
echo "  是否建议重启      ：$NEED_REBOOT"
echo "------------------------------------------------------------"
echo "  手动验证命令："
echo "    sysctl net.ipv4.tcp_congestion_control"
echo "    lsmod | grep -E \"bbr|bbrplus\""
echo "============================================================"
echo

if [ "$NEED_REBOOT" = "是" ]; then
    echo "提示："
    echo "  建议执行 reboot 重启一次，以确保新内核 / 新算法完全生效。"
    echo
fi
