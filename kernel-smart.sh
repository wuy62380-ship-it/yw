#!/usr/bin/env bash
# ============================================================================
# 极致中转一键部署脚本
# 架构：kernel-smart.sh (魔改BBRv3底层调优) + iptables (内核态零损耗转发)
# 使用：仅在【中转机】上运行
# ============================================================================

# 颜色定义
gl_bai="\033[0m"
gl_lv="\033[32m"
gl_huang="\033[33m"
gl_hui="\033[90m"
gl_red="\033[31m"
gl_cyan="\033[36m"
gl_bright="\033[97m"

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && echo -e "${gl_red}❌ 请使用 root 运行此脚本${gl_bai}" && exit 1

clear
echo -e "${gl_lv}========================================${gl_bai}"
echo -e "${gl_lv}     极致中转一键部署 (内核级 T0)      "
echo -e "${gl_lv}========================================${gl_bai}"
echo -e "${gl_hui}本脚本将执行：${gl_bai}"
echo -e "  1. 拉取并运行 kernel-smart.sh (魔改内核调优)"
echo -e "  2. 配置 iptables 内核态 DNAT 转发 (零拷贝)"
echo -e "  3. 持久化转发规则防丢失"
echo -e "${gl_lv}========================================${gl_bai}"
read -rs -n 1 -p "按任意键开始部署..."

# ============================================================================
# 第一步：部署 kernel-smart.sh (魔改底层算法)
# ============================================================================
echo -e "\n${gl_cyan}[1/3] 正在拉取 kernel-smart.sh 魔改内核脚本...${gl_bai}"

KERNEL_SCRIPT_URL="https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh"
TMP_SCRIPT="/tmp/kernel-smart.sh"

if ! curl -fsSL --connect-timeout 10 "$KERNEL_SCRIPT_URL" -o "$TMP_SCRIPT"; then
    echo -e "${gl_red}❌ 下载 kernel-smart.sh 失败！${gl_bai}"
    echo -e "${gl_huang}可能是网络问题或 GitHub 被墙。${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}是否跳过内核调优，仅配置 iptables 转发？
echo -e "${gl_hui}----------------------------------------${gl_bai}"
    else
        echo -e "${gl_hui}已取消部署。${gl_bai}"; exit 1
    fi
else
    chmod +x "$TMP_SCRIPT"
    echo -e "${gl_lv}✅ 下载成功，正在执行内核调优...${gl_bai}"
    echo -e "${gl_huang}>>> 请在弹出的菜单中完成你的魔改 BBRv3 设置 <<<${gl_bai}"
    echo -e "${gl_hui}设置完成后，脚本会自动返回此处继续配置转发。${gl_bai}"
    echo -e "${gl_hui}----------------------------------------${gl_bai}"
    
    # 运行魔改脚本，运行完毕后继续
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
    echo -e "${gl_lv}✅ 内核调优步骤完成！${gl_bai}"
fi

# ============================================================================
# 第二步：强制开启内核转发 & 配置 iptables
# ============================================================================
echo -e "\n${gl_cyan}[2/3] 配置 iptables 内核态高透转发...${gl_bai}"

# 确保内核 IP 转发开启（无论 kernel-smart.sh 有没有开，这里强制保底）
if ! grep -q "^net.ipv4.ip_forward.*=.*1" /etc/sysctl.conf /etc/sysctl.d/* 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# 交互获取参数
while true; do
    read -e -p "$(echo -e "${gl_cyan}请输入落地机的真实 IP: ${gl_bai}")" BACKEND_IP
    [[ "$BACKEND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    echo -e "${gl_red}IP 格式错误，请重新输入！${gl_bai}"
done

while true; do
    read -e -p "$(echo -e "${gl_cyan}请输入落地机的监听端口: ${gl_bai}")" BACKEND_PORT
    [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && break
    echo -e "${gl_red}端口格式错误，请重新输入！${gl_bai}"
done

while true; do
    read -e -p "$(echo -e "${gl_cyan}请输入中转机对外暴露的端口: ${gl_bai}")" FRONTEND_PORT
    [[ "$FRONTEND_PORT" =~ ^[0-9]+$ ]] && break
    echo -e "${gl_red}端口格式错误，请重新输入！${gl_bai}"
done

# 检查规则是否已存在（防重复添加）
if iptables -t nat -C PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT" 2>/dev/null; then
    echo -e "${gl_huang}⚠️ 检测到端口 $FRONTEND_PORT 的转发规则已存在！${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}是否覆盖/跳过？
    if [ "$OVERWRITE" != "y" ]; then echo -e "${gl_hui}已跳过。${gl_bai}"; exit 0; fi
    # 删除旧规则
    iptables -t nat -D PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT" 2>/dev/null
    echo -e "${gl_hui}已清理旧规则。${gl_bai}"
fi

# 添加 DNAT 规则 (入站改写目的地址，实现转发)
iptables -t nat -A PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT"

# 添加精准 SNAT 规则 (仅对发往落地机的流量伪装源IP，确保回程正确，不搞乱中转机全局网络)
if ! iptables -t nat -C POSTROUTING -d "$BACKEND_IP" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -d "$BACKEND_IP" -j MASQUERADE
fi

echo -e "${gl_lv}✅ iptables 转发规则添加成功！${gl_bai}"

# ============================================================================
# 第三步：持久化规则
# ============================================================================
echo -e "\n${gl_cyan}[3/3] 持久化转发规则 (防止重启丢失)...${gl_bai}"

SAVE_SUCCESS=0
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save > /dev/null 2>&1 && SAVE_SUCCESS=1
elif [ -f /etc/redhat-release ] && command -v iptables-service >/dev/null 2>&1; then
    service iptables save > /dev/null 2>&1 && SAVE_SUCCESS=1
else
    # 尝试手动保存
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null && SAVE_SUCCESS=1
fi

if [ "$SAVE_SUCCESS" -eq 1 ]; then
    echo -e "${gl_lv}✅ 规则持久化成功！重启不会丢失。${gl_bai}"
else
    echo -e "${gl_huang}⚠️ 自动持久化失败，请手动安装：${gl_bai}"
    echo -e "${gl_hui}Debian/Ubuntu: apt install iptables-persistent -y${gl_bai}"
    echo -e "${gl_hui}CentOS/RedHat: yum install iptables-services -y && systemctl enable iptables${gl_bai}"
fi

# ============================================================================
# 完成提示
# ============================================================================
PUBLIC_IP=$(curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -s --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null)

echo -e "\n${gl_lv}========================================${gl_bai}"
echo -e "${gl_lv}          🚀 极致中转配置完毕！          ${gl_bai}"
echo -e "${gl_lv}========================================${gl_bai}"
echo -e "中转机入口: ${gl_cyan}${PUBLIC_IP:-未知IP}:${FRONTEND_PORT}${gl_bai}"
echo -e "转发至后端: ${gl_cyan}${BACKEND_IP}:${BACKEND_PORT}${gl_bai}"
echo -e "${gl_lv}========================================${gl_bai}"
echo -e "${gl_bright}💡 客户端链接怎么填？${gl_bai}"
echo -e "复制【落地机】生成的链接，把 IP 改成 ${gl_lv}${PUBLIC_IP:-中转机IP}${gl_bai}，"
echo -e "端口改成 ${gl_lv}${FRONTEND_PORT}${gl_bai}，其他参数（UUID/公钥/SNI等）绝对不要动！"
echo -e "${gl_lv}----------------------------------------${gl_bai}"
echo -e "${gl_bright}💡 查看当前所有转发规则？${gl_bai}"
echo -e "执行: ${gl_hui}iptables -t nat -L PREROUTING -n --line-numbers${gl_bai}"
echo -e "${gl_lv}----------------------------------------${gl_bai}"
echo -e "${gl_bright}💡 如何删除这条转发规则？${gl_bai}"
echo -e "执行: ${gl_hui}iptables -t nat -D PREROUTING -p tcp --dport ${FRONTEND_PORT} -j DNAT --to-destination ${BACKEND_IP}:${BACKEND_PORT}${gl_bai}"
echo -e "${gl_lv}========================================${gl_bai}"
