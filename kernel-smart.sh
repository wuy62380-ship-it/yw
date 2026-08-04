#!/usr/bin/env bash

if [ -t 0 ]; then :; else exec </dev/tty; fi

gl_bai=$'\033[0m'; gl_lv=$'\033[32m'; gl_huang=$'\033[33m'; gl_hui=$'\033[90m'; gl_red=$'\033[31m'; gl_kjlan=$'\033[36m'
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"
SB_CONF_LOCK="/var/lock/sing-box-config.lock"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
META_DIR="/etc/sing-box/meta"

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
            apt-get install -y curl wget jq openssl iptables ip6tables tar iproute2 procps coreutils iptables-persistent >/dev/null 2>&1
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

smart_auto_optimize() {
    clear
    echo -e "${G}╔═══════════════════════════════════════════╗${R}"
    echo -e "${G}║      🚀 智能自动优化 (仅开 BBR+fq)        ║${R}"
    echo -e "${G}╚═══════════════════════════════════════════╝${R}"
    sleep 1
    cat > /etc/sysctl.d/99-yw-optimize.conf << EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
EOF
    if ! sysctl -p /etc/sysctl.d/99-yw-optimize.conf >/dev/null 2>&1; then
        echo -e "${RED}⚠ sysctl 部分应用失败，请检查内核支持情况${R}"
    fi
    echo -e "${G}✅ 优化完成！已启用最安全的 BBR 模式。${R}"
    read -rs -n 1 -p "按任意键继续..."
}

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

sb_add_reality() {
    sb_check || return
    local port=$(shuf -i 10000-65535 -n 1)
    local uuid=$($SB_BIN generate uuid)
    # 修复：换回参考脚本里的 SNI
    local sni="apple.com"
    local keys_output=$($SB_BIN generate reality-keypair)
    local priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}')
    local pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}')
    local short_id=$($SB_BIN generate rand --hex 4)
    local node_tag="vless-reality-${port}"
    
    (
        flock -x 200
        cp "$SB_CONF" "${SB_CONF}.bak"
        
        local node_json=$(cat <<EOF
{
  "tag": "$node_tag",
  "type": "vless",
  "listen": "::",
  "listen_port": $port,
  "users": [{"uuid": "$uuid", "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": true,
    "server_name": "$sni",
    "reality": {
      "enabled": true,
      "handshake": {"server": "$sni", "server_port": 443},
      "private_key": "$priv_key",
      "short_id": ["$short_id"]
    }
  }
}
EOF
)
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
    local port=$(shuf -i 10000-65535 -n 1)
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
        
        local node_json=$(cat <<EOF
{
  "tag": "$node_tag",
  "type": "hysteria2",
  "listen": "::",
  "listen_port": $port,
  "users": [{"password": "$pass"}],
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "${cert_dir}/cert.pem",
    "key_path": "${cert_dir}/key.pem"
  },
  "ignore_client_bandwidth": false
}
EOF
)
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
        echo -e "    ${H}[0] 返回主菜单${R}"
        read -e -p "  选择: " c
        case "$c" in
            1) clear; sb_install ;;
            2) clear; sb_add_reality ;;
            3) clear; sb_add_hysteria2 ;;
            4) clear; sb_show_links ;;
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
        echo -e "    ${Y}[1] 🚀 开启 BBR 网络优化${R}"
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
