#!/usr/bin/env bash

if [ -t 0 ]; then :; else exec </dev/tty; fi

gl_bai=$'\033[0m'; gl_lv=$'\033[32m'; gl_huang=$'\033[33m'; gl_hui=$'\033[90m'; gl_red=$'\033[31m'; gl_kjlan=$'\033[36m'
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"
SB_CONF_LOCK="/var/lock/sing-box-config.lock"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
META_DIR="/etc/sing-box/meta"
SYSCTL_CONF="/etc/sysctl.d/99-yw-optimize.conf"
MODE_FILE="/etc/yw_sysctl_mode"

mkdir -p /var/lock 2>/dev/null
mkdir -p "$META_DIR" 2>/dev/null

root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    root_use
    local need_update=0
    for cmd in curl wget jq openssl iptables ip6tables tar ip ss shuf; do
        command -v $cmd >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget jq openssl iptables ip6tables tar iproute2 procps coreutils iptables-persistent gnupg >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum update -y >/dev/null 2>&1
            yum install -y curl wget jq openssl iptables ip6tables tar iproute procps-ng coreutils iptables-services >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf update -y >/dev/null 2>&1
            dnf install -y curl wget jq openssl iptables ip6tables tar iproute procps-ng coreutils iptables-services >/dev/null 2>&1
        fi
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
    echo -e "${Y}正在同步系统时间...${R}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable systemd-timesyncd >/dev/null 2>&1
        systemctl restart systemd-timesyncd >/dev/null 2>&1
    fi
    timedatectl set-ntp true >/dev/null 2>&1
    sleep 2
}

get_my_ip() { 
    local server_ip=$(curl -s4 --max-time 6 https://api4.ipify.org 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
    echo "$server_ip"
}

ask_reboot() {
    read -e -p "是否立即重启服务器以应用新内核？[Y/n]: " rb
    if [[ "$rb" =~ ^[Yy]$|^$ ]]; then
        echo -e "${Y}系统将在 3 秒后重启...${R}"
        sleep 3
        reboot
    else
        echo -e "${Y}已跳过重启，请稍后手动执行 reboot 命令。${R}"
    fi
}

# ================= 网络与内核优化 =================
apply_optimize() {
    local mode=$1
    local mode_name=$2
    echo -e "${Y}切换到${mode_name}...${R}"
    echo -e "${Y}写入优化配置...${R}"
    
    if [ "$mode" == "balance" ]; then
        cat > "$SYSCTL_CONF" << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 1000000
net.core.somaxconn = 32768
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF
    elif [ "$mode" == "live" ]; then
        cat > "$SYSCTL_CONF" << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
fs.file-max = 1000000
net.core.somaxconn = 32768
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.udp_mem = 379008 504512 759360
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
EOF
    fi

    echo "$mode_name" > "$MODE_FILE"
    
    echo -e "${Y}应用优化参数...${R}"
    local result=$(sysctl -p "$SYSCTL_CONF" 2>&1)
    local applied=$(echo "$result" | grep -c "=")
    local skipped=$(echo "$result" | grep -c "cannot stat")
    
    echo -e "${G}已应用 ${applied} 项参数，跳过 ${skipped} 项不支持的参数${R}"
    
    local mem=$(free -m | awk '/Mem:/{print $2}')
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "${G}${mode_name} 优化完成！配置已持久化到 ${SYSCTL_CONF}${R}"
    echo -e "内存: ${mem}MB | 拥塞算法: ${cc} | 队列: ${qdisc}"
}

restore_default() {
    echo -e "${Y}还原默认设置...${R}"
    rm -f "$SYSCTL_CONF"
    rm -f "$MODE_FILE"
    
    sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=0 >/dev/null 2>&1
    
    local mem=$(free -m | awk '/Mem:/{print $2}')
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    echo -e "${G}已还原系统默认网络配置${R}"
    echo -e "内存: ${mem}MB | 拥塞算法: ${cc} | 队列: ${qdisc}"
}

bbr_kernel_manage() {
    local vi=$(systemd-detect-virt 2>/dev/null)
    if [[ "$vi" =~ lxc|openvz ]]; then
        echo -e "${RED}当前VPS的架构为 $vi，不支持开启原版BBR加速${R}"
        read -rs -n 1 -p ""; return
    fi

    local current_kernel=$(uname -r)
    echo -e "您当前内核版本: ${C}$current_kernel${R}\n"
    
    if echo "$current_kernel" | grep -q "xanmod"; then
        echo -e "${RED}检测到当前正在使用 XanMod 内核。${R}"
        echo -e "${Y}如需切换到官方原版 BBR 内核，需要先卸载 XanMod 内核并安装官方内核。${R}\n"
        echo -e "${Y}1. 卸载 XanMod 并安装官方原版内核              2. 返回上一级${R}"
        echo -e "------------------------"
        read -e -p "请选择: " c
        if [ "$c" == "1" ]; then
            if ! command -v apt-get >/dev/null 2>&1; then
                echo -e "${RED}仅支持 Debian/Ubuntu 系统进行此操作${R}"
                read -rs -n 1 -p ""; return
            fi
            
            echo -e "${Y}正在彻底卸载 XanMod 内核包...${R}"
            apt purge -y $(dpkg -l | grep -i xanmod | awk '{print $2}') -y >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/xanmod-release.list
            rm -f /usr/share/keyrings/xanmod-archive-keyring.gpg
            apt autoremove -y --purge >/dev/null 2>&1
            
            echo -e "${Y}正在安装官方原版内核...${R}"
            apt update -y >/dev/null 2>&1
            apt install -y linux-image-amd64 linux-headers-amd64 >/dev/null 2>&1 || apt install -y linux-image-generic linux-headers-generic >/dev/null 2>&1
            
            if command -v update-grub >/dev/null 2>&1; then
                sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/g' /etc/default/grub
                update-grub
            else
                grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
            fi
            
            echo -e "\n${G}当前系统中已安装的内核镜像文件：${R}"
            ls /boot/vmlinuz-*
            
            echo -e "\n${G}✅ 已尝试切换为官方原版内核。${R}"
            ask_reboot
        fi
    else
        echo -e "${Y}官方原版 BBR 内核管理${R}"
        echo -e "------------------------"
        echo -e "${Y}1. 安装/更新原版 BBR 内核              2. 返回上一级${R}"
        echo -e "------------------------"
        read -e -p "请选择: " c
        if [ "$c" == "1" ]; then
            echo -e "${Y}点击任意键，即可开启原版BBR加速，ctrl+c退出${R}"
            read -rs -n 1
            bash <(curl -Ls https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)
        fi
    fi
}

smart_auto_optimize() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🚀 网络与内核优化中心             ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        
        local current_kernel=$(uname -r)
        local current_mode="默认设置"
        if [ -f "$MODE_FILE" ]; then
            current_mode=$(cat "$MODE_FILE")
        fi
        
        echo -e "当前内核: ${C}$current_kernel${R}"
        echo -e "当前模式: ${Y}$current_mode${R}\n"
        echo -e "Linux系统内核参数优化"
        echo -e "--------------------"
        echo -e "${Y}1 均衡优化模式：       ${R}在性能与资源消耗之间取得平衡，适合日常使用。"
        echo -e "${Y}2 直播优化模式：       ${R}针对直播推流优化，UDP 缓冲区加大，减少延迟。"
        echo -e "${Y}3 还原默认设置：       ${R}将系统设置还原为默认配置。"
        echo -e "${C}4 XanMod BBRv3 内核管理${R}"
        echo -e "${C}5 官方原版 BBR 内核管理${R}"
        echo -e "--------------------"
        echo -e "${H}0. 返回上一级选单${R}"
        echo -e "--------------------"
        read -e -p "请输入你的选择: " c
        
        case "$c" in
            1) clear; apply_optimize balance "均衡优化模式"; echo "操作完成"; read -rs -n 1 -p "按任意键继续..." ;;
            2) clear; apply_optimize live "直播优化模式"; echo "操作完成"; read -rs -n 1 -p "按任意键继续..." ;;
            3) clear; restore_default; echo "操作完成"; read -rs -n 1 -p "按任意键继续..." ;;
            4) clear; xanmod_manage ;;
            5) clear; bbr_kernel_manage ;;
            0|"") break ;;
        esac
    done
}

# 新增：XanMod 下载与安装逻辑
xanmod_download_and_install() {
    echo -e "${Y}正在获取最新 XanMod BBRv3 内核版本...${R}"
    local deb_url=$(curl -sL https://api.github.com/repos/xanmod/linux/releases/latest | jq -r '.assets[] | select(.name | test("linux-image.*x64v3.*amd64.deb$")) | .browser_download_url' | head -n 1)
    local deb_name=$(basename "$deb_url")

    if [ -z "$deb_url" ]; then
        echo -e "${RED}获取下载链接失败，可能是网络问题或未找到适合 x64v3 架构的包。${R}"
        read -rs -n 1 -p ""; return 1
    fi

    echo -e "${Y}正在下载 $deb_name ...${R}"
    curl -L -o "/tmp/$deb_name" "$deb_url" 2>/dev/null

    if [ ! -f "/tmp/$deb_name" ]; then
        echo -e "${RED}下载失败！请稍后重试。${R}"
        read -rs -n 1 -p ""; return 1
    fi

    echo -e "${Y}正在安装...${R}"
    dpkg -i "/tmp/$deb_name" 2>/dev/null || apt install -f -y >/dev/null 2>&1
    
    rm -f "/tmp/$deb_name"

    if command -v update-grub >/dev/null 2>&1; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/g' /etc/default/grub
        update-grub
    else
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi

    echo -e "\n${G}当前系统中已安装的内核镜像文件：${R}"
    ls /boot/vmlinuz-*

    echo -e "\n${G}✅ BBRv3 内核安装完成！${R}"
    ask_reboot
}

xanmod_uninstall() {
    echo -e "${Y}正在查找并卸载 XanMod 内核...${R}"
    local xanmod_pkgs=$(dpkg -l | grep -i xanmod | awk '{print $2}')
    if [ -n "$xanmod_pkgs" ]; then
        dpkg --purge $xanmod_pkgs >/dev/null 2>&1 || apt purge -y $xanmod_pkgs >/dev/null 2>&1
        apt autoremove -y --purge >/dev/null 2>&1
        if command -v update-grub >/dev/null 2>&1; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/g' /etc/default/grub
            update-grub
        else
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
        echo -e "${G}✅ BBRv3 内核已卸载。${R}"
        ask_reboot
    else
        echo -e "${Y}未找到 XanMod 内核包，无需卸载。${R}"
    fi
}

xanmod_manage() {
    if ! command -v dpkg >/dev/null 2>&1; then
        echo -e "${RED}仅支持 Debian/Ubuntu 系统安装 XanMod 内核${R}"
        read -rs -n 1 -p ""; return
    fi

    local current_kernel=$(uname -r)
    if echo "$current_kernel" | grep -q "xanmod"; then
        echo -e "${G}您已安装xanmod的BBRv3内核${R}"
        echo -e "当前内核版本: ${C}$current_kernel${R}\n"
        echo -e "${Y}内核管理${R}"
        echo -e "------------------------"
        echo -e "${Y}1. 更新BBRv3内核              2. 卸载BBRv3内核${R}"
        echo -e "------------------------"
        echo -e "${H}0. 返回上一级选单${R}"
        read -e -p "请选择: " c
        case "$c" in
            1) xanmod_download_and_install ;;
            2) xanmod_uninstall ;;
            0|"") return ;;
        esac
    else
        echo -e "${Y}当前未安装 XanMod BBRv3 内核 (当前内核: $current_kernel)${R}"
        echo -e "1. 安装 BBRv3 内核"
        echo -e "0. 返回上一级选单"
        read -e -p "请选择: " c
        if [ "$c" == "1" ]; then
            xanmod_download_and_install
        fi
    fi
}

# ================= Sing-Box 核心 =================
sb_init_conf() { 
    mkdir -p /etc/sing-box
    cat > "$SB_CONF" <<'EOF'
{
  "log": {"disabled": false, "level": "info", "timestamp": true},
  "inbounds": [],
  "outbounds": [
    {"type": "selector", "tag": "proxy", "outbounds": ["direct"], "default": "direct"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
}

sb_check() { 
    if ! command -v $SB_BIN >/dev/null 2>&1; then 
        echo -e "${RED}请先安装 Sing-Box${R}"; read -rs -n 1 -p ""; return 1; 
    fi
    
    if ! systemctl is-active --quiet sing-box 2>/dev/null; then
        systemctl restart sing-box >/dev/null 2>&1
        sleep 2
        if ! systemctl is-active --quiet sing-box 2>/dev/null; then
            echo -e "${Y}检测到 Sing-Box 服务未运行，可能是旧配置损坏，正在自动重置基础配置...${R}"
            mv "$SB_CONF" "${SB_CONF}.bak.$(date +%s)" 2>/dev/null
            sb_init_conf
            systemctl restart sing-box >/dev/null 2>&1
            sleep 2
        fi
    fi
    
    if ! $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        echo -e "${Y}检测到配置文件语法错误，正在强制重置...${R}"
        mv "$SB_CONF" "${SB_CONF}.bak.$(date +%s)" 2>/dev/null
        sb_init_conf
        systemctl restart sing-box >/dev/null 2>&1
    fi
    return 0
}

sb_install() {
    if command -v $SB_BIN >/dev/null 2>&1; then echo -e "${Y}Sing-Box 已安装！${R}"; read -rs -n 1 -p ""; return; fi
    local arch=$(uname -m); case "$arch" in x86_64) arch="amd64";; aarch64) arch="arm64";; *) echo -e "${RED}❌ 不支持 ${arch}${R}"; return 1;; esac
    
    local latest_ver=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
    [ -z "$latest_ver" ] && latest_ver="1.11.4"
    echo -e "${Y}正在安装 Sing-Box v${latest_ver}...${R}"
    mkdir -p /etc/sing-box
    curl -L -o /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz" 2>/dev/null
    tar xzf /tmp/sb.tar.gz -C /tmp 2>/dev/null || { echo -e "${RED}❌ 解压失败${R}"; return 1; }
    [ -f "/tmp/sing-box-${latest_ver}-linux-${arch}/sing-box" ] || { echo -e "${RED}❌ 二进制文件缺失${R}"; return 1; }
    mv /tmp/sing-box-${latest_ver}-linux-${arch}/sing-box $SB_BIN
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
    chmod +x $SB_BIN
    sb_init_conf
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
ExecStart=$SB_BIN run -c $SB_CONF
Restart=on-failure
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box --now >/dev/null 2>&1
    echo -e "${G}✅ 安装成功！${R}"
    read -rs -n 1 -p ""
}

save_iptables() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    fi
}

open_port() {
    local port=$1
    iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
    iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${port} -j ACCEPT
    ip6tables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport ${port} -j ACCEPT
    ip6tables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport ${port} -j ACCEPT
    save_iptables
}

close_port() {
    local port=$1
    iptables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    save_iptables
}

input_custom_port() {
    local port
    while true; do
        read -e -p "请输入端口 (10000-65535，回车随机生成): " port
        if [ -z "$port" ]; then
            port=$(shuf -i 10000-65535 -n 1)
            echo -e "${Y}已随机生成端口: $port${R}"
            break
        elif ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 10000 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}端口必须在 10000-65535 之间，请重新输入${R}"
        elif ss -tuln | grep -q ":$port "; then
            echo -e "${RED}端口 $port 已被占用，请重新输入${R}"
        else
            break
        fi
    done
    echo "$port"
}

sb_add_reality() {
    sb_check || return
    echo -e "${Y}设置 VLESS-Reality 端口${R}"
    local port=$(input_custom_port)
    local uuid=$($SB_BIN generate uuid)
    local sni="apple.com"
    local keys_output=$($SB_BIN generate reality-keypair)
    local priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}')
    local pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}')
    local short_id=$($SB_BIN generate rand --hex 4)
    local node_tag="vless-reality-${port}"
    
    (
        flock -x 200
        cp "$SB_CONF" "${SB_CONF}.bak"
        
        local node_json=$(jq -n \
          --arg tag "$node_tag" \
          --argjson port $port \
          --arg uuid "$uuid" \
          --arg sni "$sni" \
          --arg priv_key "$priv_key" \
          --arg short_id "$short_id" \
          '{
            tag: $tag,
            type: "vless",
            listen: "::",
            listen_port: $port,
            users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
            tls: {
              enabled: true,
              server_name: $sni,
              reality: {
                enabled: true,
                handshake: {server: $sni, server_port: 443},
                private_key: $priv_key,
                short_id: [$short_id]
              }
            }
          }')
        
        jq --argjson node "$node_json" '.inbounds += [$node]' "$SB_CONF" > "$SB_CONF.tmp"
        
        if $SB_BIN check -c "$SB_CONF.tmp" > /tmp/check.log 2>&1; then
            mv "$SB_CONF.tmp" "$SB_CONF"
            open_port $port
            
            cat > "${META_DIR}/${node_tag}.json" <<EOF
{"public_key":"$pub_key","short_id":"$short_id","sni":"$sni","uuid":"$uuid","port":$port}
EOF
            
            systemctl restart sing-box
            sleep 2
            if ! systemctl is-active --quiet sing-box; then
                echo -e "${RED}❌ Sing-Box 启动失败！可能是端口冲突。${R}"
                journalctl -u sing-box -n 10 --no-pager
                cp "${SB_CONF}.bak" "$SB_CONF"
                rm -f "${META_DIR}/${node_tag}.json"
                systemctl restart sing-box
            else
                echo -e "${G}✅ VLESS-Reality 部署成功！${R}"
                local server_ip=$(get_my_ip)
                local link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#YW-Reality-${port}"
                echo -e "${C}节点链接: ${link}${R}"
            fi
        else
            echo -e "${RED}❌ 校验失败，错误详情：${R}"
            cat /tmp/check.log
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -rs -n 1 -p ""
}

sb_add_hysteria2() {
    sb_check || return
    echo -e "${Y}设置 Hysteria2 端口${R}"
    local port=$(input_custom_port)
    local pass=$($SB_BIN generate rand --hex 16)
    local sni="www.bing.com"
    local cert_dir="/etc/sing-box/certs/hy2-${port}"
    mkdir -p "$cert_dir"
    openssl ecparam -genkey -name prime256v1 -out "${cert_dir}/key.pem" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" -subj "/CN=${sni}" 2>/dev/null
    local node_tag="hysteria2-${port}"
    
    (
        flock -x 200
        cp "$SB_CONF" "${SB_CONF}.bak"
        
        local node_json=$(jq -n \
          --arg tag "$node_tag" \
          --argjson port $port \
          --arg pass "$pass" \
          --arg cert "${cert_dir}/cert.pem" \
          --arg key "${cert_dir}/key.pem" \
          '{
            tag: $tag,
            type: "hysteria2",
            listen: "::",
            listen_port: $port,
            users: [{password: $pass}],
            tls: {
              enabled: true,
              alpn: ["h3"],
              certificate_path: $cert,
              key_path: $key
            },
            ignore_client_bandwidth: false
          }')
        
        jq --argjson node "$node_json" '.inbounds += [$node]' "$SB_CONF" > "$SB_CONF.tmp"
        
        if $SB_BIN check -c "$SB_CONF.tmp" > /tmp/check.log 2>&1; then
            mv "$SB_CONF.tmp" "$SB_CONF"
            open_port $port
            systemctl restart sing-box
            sleep 2
            if ! systemctl is-active --quiet sing-box; then
                echo -e "${RED}❌ Sing-Box 启动失败！${R}"
                journalctl -u sing-box -n 10 --no-pager
                cp "${SB_CONF}.bak" "$SB_CONF"
                systemctl restart sing-box
            else
                echo -e "${G}✅ Hysteria2 部署成功！${R}"
                local server_ip=$(get_my_ip)
                local link="hysteria2://${pass}@${server_ip}:${port}?security=tls&sni=${sni}&alpn=h3&insecure=1#YW-Hy2-${port}"
                echo -e "${C}节点链接: ${link}${R}"
            fi
        else
            echo -e "${RED}❌ 校验失败，错误详情：${R}"
            cat /tmp/check.log
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -rs -n 1 -p ""
}

sb_del_node() {
    sb_check || return
    
    local tags=($(jq -r '.inbounds[].tag' "$SB_CONF" 2>/dev/null))
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${Y}当前没有任何节点可删除。${R}"
        read -rs -n 1 -p ""
        return
    fi
    
    echo -e "${Y}当前已有节点，请选择要删除的节点序号，或直接输入端口号删除：${R}"
    local i=1
    for tag in "${tags[@]}"; do
        echo -e "  ${G}[$i]${R} $tag"
        ((i++))
    done
    echo -e "  ${H}[0] 返回${R}"
    
    read -e -p "请选择: " c
    if [ "$c" == "0" ] || [ -z "$c" ]; then return; fi
    
    local tag=""
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#tags[@]} ]; then
        tag="${tags[$((c-1))]}"
    else
        tag=$(jq -r --arg p "$c" '.inbounds[] | select(.listen_port==($p|tonumber)) | .tag' "$SB_CONF" 2>/dev/null)
    fi
    
    if [ -z "$tag" ]; then
        echo -e "${RED}未找到对应的节点${R}"
        read -rs -n 1 -p ""
        return
    fi
    
    local port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .listen_port' "$SB_CONF")
    local type=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag==$t) | .type' "$SB_CONF")
    
    (
        flock -x 200
        cp "$SB_CONF" "${SB_CONF}.bak"
        
        jq --arg t "$tag" 'del(.inbounds[] | select(.tag==$t))' "$SB_CONF" > "$SB_CONF.tmp"
        
        if $SB_BIN check -c "$SB_CONF.tmp" > /tmp/check.log 2>&1; then
            mv "$SB_CONF.tmp" "$SB_CONF"
            close_port $port
            rm -f "${META_DIR}/${tag}.json"
            if [ "$type" == "hysteria2" ]; then
                rm -rf "/etc/sing-box/certs/hy2-${port}"
            fi
            
            systemctl restart sing-box
            sleep 2
            if systemctl is-active --quiet sing-box; then
                echo -e "${G}✅ 节点 $tag 已删除！${R}"
            else
                echo -e "${RED}❌ Sing-Box 启动失败，正在回滚...${R}"
                journalctl -u sing-box -n 10 --no-pager
                cp "${SB_CONF}.bak" "$SB_CONF"
                systemctl restart sing-box
            fi
        else
            echo -e "${RED}❌ 删除节点失败，错误详情：${R}"
            cat /tmp/check.log
            cp "${SB_CONF}.bak" "$SB_CONF"
            rm -f "$SB_CONF.tmp"
        fi
    ) 200>"$SB_CONF_LOCK"
    read -rs -n 1 -p ""
}

sb_manage_ports() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🔥 端口防火墙管理 (TCP+UDP)       ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 放行指定端口${R}"
        echo -e "    ${Y}[2] 关闭指定端口${R}"
        echo -e "    ${H}[0] 返回上一级${R}"
        read -e -p "  请选择: " c
        case "$c" in
            1) 
                read -e -p "请输入要放行的端口号: " p
                if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                    open_port $p
                    echo -e "${G}✅ 端口 $p 已放行 (TCP+UDP)${R}"
                else
                    echo -e "${RED}端口号无效${R}"
                fi
                read -rs -n 1 -p ""
                ;;
            2) 
                read -e -p "请输入要关闭的端口号: " p
                if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                    close_port $p
                    echo -e "${G}✅ 端口 $p 已关闭 (TCP+UDP)${R}"
                else
                    echo -e "${RED}端口号无效${R}"
                fi
                read -rs -n 1 -p ""
                ;;
            0|"") break ;;
        esac
    done
}

sb_show_links() {
    sb_check || return
    local server_ip=$(get_my_ip)
    echo -e "\n${Y}===== 节点链接 =====${R}"
    
    (
        flock -s 200
        
        jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .tag' "$SB_CONF" 2>/dev/null | while read -r tag; do
            if [ -n "$tag" ] && [ -f "${META_DIR}/${tag}.json" ]; then
                local meta="${META_DIR}/${tag}.json"
                local uuid=$(jq -r '.uuid' "$meta")
                local port=$(jq -r '.port' "$meta")
                local sni=$(jq -r '.sni' "$meta")
                local pub_key=$(jq -r '.public_key' "$meta")
                local short_id=$(jq -r '.short_id' "$meta")
                echo "vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&headerType=none#${tag}"
            fi
        done
        
        jq -r --arg ip "$server_ip" '.inbounds[] | select(.type=="hysteria2") | "hysteria2://" + .users[0].password + "@" + $ip + ":" + (.listen_port|tostring) + "?security=tls&sni=" + .tls.server_name + "&alpn=h3&insecure=1#" + .tag' "$SB_CONF" 2>/dev/null
        
    ) 200>"$SB_CONF_LOCK"
    
    read -rs -n 1 -p ""
}

sb_menu() {
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║       Sing-Box 管理面板                   ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 安装 Sing-Box${R}"
        echo -e "    ${Y}[2] 添加 VLESS-Reality 节点${R}"
        echo -e "    ${Y}[3] 添加 Hysteria2 节点${R}"
        echo -e "    ${Y}[4] 查看所有节点链接${R}"
        echo -e "    ${RED}[5] 删除已添加节点 (支持按端口删除)${R}"
        echo -e "    ${C}[6] 手动管理端口放行 (TCP+UDP)${R}"
        echo -e "    ${H}[0] 返回主菜单${R}"
        read -e -p "  选择: " c
        case "$c" in
            1) clear; sb_install ;;
            2) clear; sb_add_reality ;;
            3) clear; sb_add_hysteria2 ;;
            4) clear; sb_show_links ;;
            5) clear; sb_del_node ;;
            6) clear; sb_manage_ports ;;
            0|"") break ;;
        esac
    done
}

main_menu() {
    check_env
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗${R}"
        echo -e "║          🎉 YW 服务器优化工具箱             ║${R}"
        echo -e "╚═══════════════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 🚀 网络与内核优化 (BBR/XanMod)${R}"
        echo -e "    ${Y}[2] 📦 Sing-Box 管理面板${R}"
        echo -e "    ${H}[0] 退出${R}"
        read -e -p "  请选择: " c
        case "$c" in
            1) clear; smart_auto_optimize ;;
            2) clear; sb_menu ;;
            0|"") exit 0 ;;
        esac
    done
}

main_menu
