#!/usr/bin/env bash

if [ -t 0 ]; then :; else exec </dev/tty; fi

TMP_DIR=$(mktemp -d /tmp/yw_box.XXXXXX)
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR" 2>/dev/null' EXIT
trap 'rm -rf "$TMP_DIR" 2>/dev/null; exit 130' INT
trap 'rm -rf "$TMP_DIR" 2>/dev/null; exit 143' TERM

: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[36m}"
R="${gl_bai}"; G="${gl_lv}"; Y="${gl_huang}"; H="${gl_hui}"; RED="${gl_red}"; C="${gl_kjlan}"
SB_CONF_LOCK="/var/lock/sing-box-config.lock"
mkdir -p /var/lock 2>/dev/null

root_use() { [ "$(id -u)" -ne 0 ] && { echo -e "${RED}错误：请使用 root 用户运行此脚本${R}"; exit 1; }; }

check_env() {
    root_use
    local need_update=0
    for cmd in curl wget jq openssl iptables tar ip ss free shuf; do
        command -v $cmd >/dev/null 2>&1 || need_update=1
    done
    if [ "$need_update" -eq 1 ]; then
        echo -e "${Y}正在准备基础环境...${R}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget jq openssl iptables tar iproute2 procps coreutils >/dev/null 2>&1
        echo -e "${G}✅ 基础环境准备完毕！${R}"
    fi
}

# ================= 基础工具 =================
get_my_ip() { 
    local server_ip=$(curl -s --max-time 3 https://api4.ipify.org 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}')
    echo "$server_ip"
}
url_encode() { jq -rn --arg v "$1" '$v|@uri' | sed 's/%2F/\//g'; }

# ================= 网络优化 (极简安全版) =================
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
    sysctl -p /etc/sysctl.d/99-yw-optimize.conf >/dev/null 2>&1
    echo -e "${G}✅ 优化完成！已启用最安全的 BBR 模式。${R}"
    read -rs -n 1 -p "按任意键继续..."
}

# ================= Sing-Box 核心 =================
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"

sb_init_conf() { 
    mkdir -p /etc/sing-box
    cat > "$SB_CONF" <<'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "google",
        "address": "tls://8.8.8.8"
      },
      {
        "tag": "local",
        "address": "223.5.5.5",
        "detour": "direct"
      },
      {
        "tag": "block",
        "address": "rcode://success"
      }
    ],
    "rules": [
      {
        "outbound": "any",
        "server": "local"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "selector",
      "tag": "proxy",
      "outbounds": [
        "direct"
      ],
      "default": "direct"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "dns",
      "tag": "dns-out",
      "server": "google"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
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
    local need_reset=0
    if [ ! -s "$SB_CONF" ] || ! jq -e . "$SB_CONF" >/dev/null 2>&1; then
        need_reset=1
    else
        if ! jq -e '.outbounds[] | select(.tag == "proxy")' "$SB_CONF" >/dev/null 2>&1; then
            need_reset=1
        fi
    fi
    if [ "$need_reset" -eq 1 ]; then
        echo -e "${Y}检测到配置文件损坏或为旧版，正在重置为标准模板...${R}"
        mv "$SB_CONF" "${SB_CONF}.corrupted.$(date +%s)" 2>/dev/null
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
    tar xzf /tmp/sb.tar.gz -C /tmp 2>/dev/null
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

sb_add_reality() {
    sb_check || return
    local port=$(shuf -i 10000-65535 -n 1)
    local uuid=$($SB_BIN generate uuid)
    local sni="www.apple.com"
    local keys_output=$($SB_BIN generate reality-keypair)
    local priv_key=$(echo "$keys_output" | awk '/PrivateKey/{print $2}')
    local pub_key=$(echo "$keys_output" | awk '/PublicKey/{print $2}')
    local short_id=$($SB_BIN generate rand --hex 8)
    local node_tag="vless-reality-${port}"
    
    (
        flock -x 200
        cp "$SB_CONF" "${SB_CONF}.bak"
        jq --arg p "$port" --arg u "$uuid" --arg s "$sni" --arg pk "$priv_key" --arg sid "$short_id" --arg tag "$node_tag" \
           '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":($p|tonumber),"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"alpn":["h2","http/1.1"],"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]
           | .outbounds |= map(if .tag == "proxy" then .outbounds += [$tag] | .default = $tag else . end)' "$SB_CONF" > "$TMP_DIR/sb_cfg.json" && mv "$TMP_DIR/sb_cfg.json" "$SB_CONF"
    ) 200>"$SB_CONF_LOCK"
    
    if $SB_BIN check -c "$SB_CONF" >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport ${port} -j ACCEPT
        systemctl restart sing-box
        echo -e "${G}✅ VLESS-Reality 部署成功！${R}"
        local server_ip=$(get_my_ip)
        local link="vless://${uuid}@${server_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp&spx=%2F#YW-Reality"
        echo -e "${C}节点链接: ${link}${R}"
    else
        echo -e "${RED}❌ 配置校验失败${R}"
        cp "${SB_CONF}.bak" "$SB_CONF"
    fi
    read -rs -n 1 -p ""
}

sb_show_links() {
    sb_check || return
    local server_ip=$(get_my_ip)
    echo -e "\n${Y}===== 节点链接 =====${R}"
    jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | "vless://" + (.users[0].uuid) + "@" + "'"$server_ip"':" + (.listen_port|tostring) + "?encryption=none&flow=xtls-rprx-vision&security=reality&sni=" + .tls.server_name + "&fp=chrome&pbk=" + (.tls.reality.public_key // "ERROR") + "&sid=" + (.tls.reality.short_id[0] // "") + "&type=tcp&spx=%2F#Node"' "$SB_CONF" 2>/dev/null
    read -rs -n 1 -p ""
}

sb_menu() {
    while true; do
        clear
        echo -e "${G}╔════════════════════════════════╗"
        echo -e "║       Sing-Box 极简管理面板        ║"
        echo -e "╚════════════════════════════════╝${R}"
        echo -e "    ${Y}[1] 安装 Sing-Box${R}"
        echo -e "    ${Y}[2] 添加 VLESS-Reality 节点${R}"
        echo -e "    ${Y}[3] 查看节点链接${R}"
        echo -e "    ${H}[0] 返回主菜单${R}"
        read -e -p "  选择: " c
        case "$c" in
            1) clear; sb_install ;;
            2) clear; sb_add_reality ;;
            3) clear; sb_show_links ;;
            0|"") break ;;
        esac
    done
}

# ================= 主菜单 =================
main_menu() {
    check_env
    while true; do
        clear
        echo -e "${G}╔═══════════════════════════════════════════╗"
        echo -e "║          🎉 YW 服务器优化工具箱             ║"
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
