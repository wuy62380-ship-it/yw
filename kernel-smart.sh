#!/usr/bin/env bash

if [ -f "$0" ]; then
    sed -i 's/\r$//' "$0" 2>/dev/null
fi

R="\033[0m"
G="\033[32m"
Y="\033[33m"
H="\033[90m"
RED="\033[31m"
C="\033[36m"
B="\033[97m"

[ "$(id -u)" -ne 0 ] && echo -e "${RED}请使用 root 运行${R}" && exit 1

get_my_ip() {
    local ip
    ip=$(curl -4 -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -4 -s --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null || curl -4 -s --connect-timeout 3 https://api.ipify.org 2>/dev/null)
    echo "${ip:-未知IP}"
}

# ============================================================================
# 模块 0：优选域名模块
# ============================================================================
select_sni() {
    echo -e "${Y}--- 伪装域名 (SNI) 设置 ---${R}"
    echo -e "${G}1. 使用默认伪装域名${R}"
    echo -e "${G}2. 自动优选最佳域名 (并发测速)${R}"
    echo -e "${G}3. 手动输入域名${R}"
    read -e -p "请选择 (1默认 / 2优选 / 3手动): " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2)
            echo -e "${Y}[并发测速中，约需3秒]...${R}" >&2
            local d=("aws.com" "bing.com" "snap.licdn.com" "devblogs.microsoft.com" "cdn.bizibly.com" "www.apple.com" "ts1.tc.mm.bing.net" "fpinit.itunes.apple.com" "go.microsoft.com" "catalog.gamepass.com" "gray-config-prod.api.arc-cdn.net" "apps.mzstatic.com" "tag.demandbase.com" "r.bing.com" "tag-logger.demandbase.com" "cdn-dynmedia-1.microsoft.com" "services.digitaleast.mobi" "gray.video-player.arcpublishing.com" "azure.microsoft.com" "beacon.gtv-pub.com" "amd.com" "www.joom.com" "www.stengg.com" "www.wedgehr.com" "www.cerebrium.ai" "www.nazhumi.cem" "cloudflare-ech.com")
            local f="/tmp/sb_sni_test.$$"; > "$f"
            for i in "${d[@]}"; do
                ( n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 2 -4 "https://$i" 2>/dev/null | awk '{printf "%d",$1*1000}'); [ -n "$n" ] && echo "$n $i" >> "$f" ) &
            done
            wait
            local b_d="www.microsoft.com" b_t=9999
            while read -r line; do
                local t=${line%% *}
                local dom=${line#* }
                [ "$t" -lt "$b_t" ] 2>/dev/null && b_t=$t b_d=$dom
            done < "$f"
            rm -f "$f"
            echo -e "${G}选用: $b_d (${b_t}ms)${R}" >&2
            echo "$b_d"
            ;;
        3) read -e -p "输入域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

# ============================================================================
# 模块 1：iptables 内核态转发管理
# ============================================================================
add_rule() {
    echo -e "${C}--- 添加内核态转发规则 (TCP) ---${R}"
    while true; do
        echo -e "${C}请输入落地机的真实 IP: ${R}"
        read -e -p "IP: " BACKEND_IP
        [[ "$BACKEND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo -e "${RED}IP 格式错误，请重新输入！${R}"
    done
    while true; do
        echo -e "${C}请输入落地机的监听端口: ${R}"
        read -e -p "端口: " BACKEND_PORT
        [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && break
        echo -e "${RED}端口格式错误，请重新输入！${R}"
    done
    while true; do
        echo -e "${C}请输入中转机对外暴露的端口: ${R}"
        read -e -p "端口: " FRONTEND_PORT
        [[ "$FRONTEND_PORT" =~ ^[0-9]+$ ]] && break
        echo -e "${RED}端口格式错误，请重新输入！${R}"
    done

    if iptables -t nat -C PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT" 2>/dev/null; then
        echo -e "${Y}检测到端口 $FRONTEND_PORT 的转发规则已存在！${R}"; return
    fi

    iptables -t nat -A PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT"
    if ! iptables -t nat -C POSTROUTING -d "$BACKEND_IP" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -d "$BACKEND_IP" -j MASQUERADE
    fi
    save_rules
    echo -e "${G}✅ 转发规则添加成功：${C}$(get_my_ip):${FRONTEND_PORT} -> ${BACKEND_IP}:${BACKEND_PORT}${R}"
}

del_rule() {
    echo -e "${C}--- 删除内核态转发规则 ---${R}"
    rules=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then rules+=("$line"); fi
    done < <(iptables-save -t nat | awk '/PREROUTING/ && /DNAT/')

    if [ ${#rules[@]} -eq 0 ]; then echo -e "${H}当前没有任何转发规则。${R}"; return; fi

    echo -e "${Y}当前存在的转发规则：${R}"
    idx=1; declare -A port_map; declare -A dest_map
    for rule in "${rules[@]}"; do
        port=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}')
        dest=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="--to-destination") print $(i+1)}')
        port_map[$idx]="$port"; dest_map[$idx]="$dest"
        echo -e "${G}[$idx]${R} 监听端口: ${B}$port${R}  ->  落地目标: ${B}$dest${R}"
        ((idx++))
    done

    echo -e "${C}请输入要删除的规则序号 (回车取消): ${R}"
    read -e -p "序号: " sel
    if [[ -z "$sel" ]] || ! [[ "$sel" =~ ^[0-9]+$ ]] || [ -z "${port_map[$sel]:-}" ]; then
        echo -e "${H}已取消删除。${R}"; return
    fi
    del_port="${port_map[$sel]}"; del_dest="${dest_map[$sel]}"
    iptables -t nat -D PREROUTING -p tcp --dport "$del_port" -j DNAT --to-destination "$del_dest" 2>/dev/null
    if ! iptables-save -t nat | grep "PREROUTING" | grep -q "$del_dest"; then
        iptables -t nat -D POSTROUTING -d "${del_dest%%:*}" -j MASQUERADE 2>/dev/null
    fi
    save_rules
    echo -e "${G}✅ 已成功删除端口 ${del_port} 的转发规则！${R}"
}

view_rules() {
    echo -e "${C}--- 当前中转转发规则清单 ---${R}"
    rules=()
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then rules+=("$line"); fi
    done < <(iptables-save -t nat | awk '/PREROUTING/ && /DNAT/')
    if [ ${#rules[@]} -eq 0 ]; then echo -e "${H}当前没有任何转发规则，是一片净土。${R}"; return; fi
    local my_ip; my_ip=$(get_my_ip); local idx=1
    for rule in "${rules[@]}"; do
        port=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}')
        dest=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="--to-destination") print $(i+1)}')
        echo -e "${G}[$idx]${R} ${C}客户端连接${R} -> ${B}${my_ip}:${port}${R} ${C}实际转发至${R} -> ${B}${dest}${R}"
        ((idx++))
    done
    echo -e "${H}----------------------------------------${R}"
    echo -e "${H}提示：复制落地机链接，将 IP 改为 ${my_ip}，端口改为上方对应的监听端口${R}"
}

save_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save > /dev/null 2>&1
    elif [ -f /etc/redhat-release ] && command -v iptables-service >/dev/null 2>&1; then service iptables save > /dev/null 2>&1
    else mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null; fi
}

# ============================================================================
# 模块 2：落地机管理模块 (独立子菜单)
# ============================================================================
sb_check() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}请先安装 Sing-Box 核心！${R}"; return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}请先安装 jq (apt install jq -y)！${R}"; return 1
    fi
    return 0
}

sb_init_conf() {
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ] || ! jq -e . "$conf" >/dev/null 2>&1; then
        mkdir -p /etc/sing-box
        echo '{"log":{"level":"error"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$conf"
    fi
}

sb_add_reality() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 VLESS Reality 落地节点 ---${R}"
    echo -e "${C}请输入监听端口: ${R}"
    read -e -p "端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${RED}端口错误${R}" && { read -rs -n 1 -p "按任意键返回..."; return; }

    local sni; sni=$(select_sni)

    echo -e "${Y}正在生成 UUID 和密钥对...${R}"
    local uuid priv_key pub_key keys
    uuid=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair 2>/dev/null)
    priv_key=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
    pub_key=$(echo "$keys" | grep PublicKey | awk '{print $2}')
    [ -z "$pub_key" ] && echo -e "${RED}密钥生成失败！${R}" && { read -rs -n 1 -p "按任意键返回..."; return; }

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    
    jq --argjson p "$port" --arg u "$uuid" --arg pk "$priv_key" --arg s "$sni" \
       '.inbounds += [{"type":"vless","tag":"vless-in-$p","listen":"::","listen_port":$p,"users":[{"uuid":$u,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$s,"reality":{"enabled":true,"handshake":{"server":$s,"server_port":443},"private_key":$pk}}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"

    if sing-box check -c "$conf" >/dev/null 2>&1; then
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 1
        local my_ip; my_ip=$(get_my_ip)
        local link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&type=tcp#Reality-${port}"
        echo -e "${G}✅ VLESS Reality 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
        echo -e "${H}如果是中转，请将链接中的 IP:端口 改为中转机的 IP:端口${R}"
    else
        echo -e "${RED}配置校验失败！${R}"; sing-box check -c "$conf"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

sb_add_hy2() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    echo -e "${C}--- 添加 Hysteria2 落地节点 ---${R}"
    echo -e "${C}请输入监听 UDP 端口: ${R}"
    read -e -p "端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${RED}端口错误${R}" && { read -rs -n 1 -p "按任意键返回..."; return; }

    local sni; sni=$(select_sni)

    echo -e "${Y}正在生成密码和自签证书...${R}"
    local pass crt key
    pass=$(openssl rand -base64 16)
    crt="/etc/sing-box/hy2.crt"; key="/etc/sing-box/hy2.key"
    if [ ! -f "$crt" ] || [ ! -f "$key" ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key" -out "$crt" -subj "/CN=$sni" -days 3650 2>/dev/null
        chmod 644 "$crt" "$key" 2>/dev/null
    fi

    sb_init_conf
    local conf="/etc/sing-box/config.json"
    jq --argjson p "$port" --arg pass "$pass" --arg s "$sni" \
       '.inbounds += [{"type":"hysteria2","tag":"hy2-in-$p","listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$s,"certificate_path":"/etc/sing-box/hy2.crt","key_path":"/etc/sing-box/hy2.key"}}]' \
       "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
       
    if sing-box check -c "$conf" >/dev/null 2>&1; then
        systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 1
        local my_ip; my_ip=$(get_my_ip)
        local link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#Hy2-${port}"
        echo -e "${G}✅ Hysteria2 添加成功并已启动！${R}"
        echo -e "${Y}客户端链接:${R}"
        echo -e "${B}${link}${R}"
        echo -e "${H}注意: Hysteria2 是 UDP 协议，安全组/防火墙请放行 UDP ${port}${R}"
    else
        echo -e "${RED}配置校验失败！${R}"; sing-box check -c "$conf"
    fi
    read -rs -n 1 -p "按任意键继续..."
}

sb_view_nodes() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    local conf="/etc/sing-box/config.json"
    if [ ! -f "$conf" ]; then echo -e "${H}未找到配置文件${R}"; return; fi
    
    echo -e "${C}--- 当前落地节点列表 ---${R}"
    local my_ip; my_ip=$(get_my_ip)
    local inbounds
    inbounds=$(jq -c '.inbounds[]' "$conf" 2>/dev/null)
    if [ -z "$inbounds" ]; then echo -e "${H}暂无节点${R}"; return; fi
    
    echo "$inbounds" | while IFS= read -r in; do
        local type port tag link
        type=$(echo "$in" | jq -r '.type')
        port=$(echo "$in" | jq -r '.listen_port')
        
        if [ "$type" = "vless" ]; then
            echo -e "${G}[VLESS Reality]${R} 端口: ${B}${port}${R}"
            echo -e "${H}提示: 链接在添加时已展示，如需再次获取，请删除后重新添加。${R}"
        elif [ "$type" = "hysteria2" ]; then
            local pass sni
            pass=$(echo "$in" | jq -r '.users[0].password')
            sni=$(echo "$in" | jq -r '.tls.server_name')
            local link="hysteria2://${pass}@${my_ip}:${port}?insecure=1&sni=${sni}#Hy2-${port}"
            echo -e "${G}[Hysteria2]${R} 端口: ${B}${port}${R}"
            echo -e "${Y}链接: ${B}${link}${R}"
        fi
        echo -e "${H}----------------------------------------${R}"
    done
    read -rs -n 1 -p "按任意键继续..."
}

sb_del_node() {
    sb_check || { read -rs -n 1 -p "按任意键返回..."; return; }
    local conf="/etc/sing-box/config.json"
    sb_view_nodes
    echo -e "${C}请输入要删除的节点监听端口: ${R}"
    read -e -p "端口: " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${RED}端口错误${R}" && return
    
    local count
    count=$(jq --argjson p "$port" '[.inbounds[] | select(.listen_port == $p)] | length' "$conf")
    if [ "$count" -eq 0 ]; then echo -e "${H}未找到端口 ${port} 的节点${R}"; return; fi
    
    jq --argjson p "$port" 'del(.inbounds[] | select(.listen_port == $p))' "$conf" > /tmp/sb_cfg.json && mv /tmp/sb_cfg.json "$conf"
    systemctl restart sing-box
    echo -e "${G}✅ 已删除端口 ${port} 的节点并重启服务${R}"
    read -rs -n 1 -p "按任意键继续..."
}

sb_manage_menu() {
    while true; do
        clear
        local sb_status="${RED}未安装${R}"
        if command -v sing-box >/dev/null 2>&1; then
            if systemctl is-active --quiet sing-box 2>/dev/null; then sb_status="${G}运行中 ✅${R}"
            else sb_status="${Y}已停止${R}"; fi
        fi
        echo -e "${G}========================================${R}"
        echo -e "${G}       落地机节点管理模块             "
        echo -e "${G}========================================${R}"
        echo -e "核心状态: ${sb_status}"
        echo -e "${G}========================================${R}"
        echo -e "${C}1.${R} 安装/更新 Sing-Box 核心"
        echo -e "${G}2.${R} 添加 VLESS Reality 节点 (含优选SNI)"
        echo -e "${G}3.${R} 添加 Hysteria2 节点 (含优选SNI)"
        echo -e "${H}4.${R} 查看节点与链接"
        echo -e "${RED}5.${R} 删除节点 (按端口)"
        echo -e "${H}6.${R} 重启/停止/查看日志"
        echo -e "${G}========================================${R}"
        echo -e "${H}0.${R} 返回主菜单"
        echo -e "${G}========================================${R}"
        
        read -e -p "请输入选择: " c
        case $c in
            1) 
                echo -e "${C}正在连接官方源安装...${R}"
                if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash
                elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash
                else echo -e "${RED}不支持该系统${R}"; fi
                read -rs -n 1 -p "按任意键继续..." ;;
            2) sb_add_reality ;;
            3) sb_add_hy2 ;;
            4) sb_view_nodes ;;
            5) sb_del_node ;;
            6)
                echo -e "${C}1.重启 2.停止 3.日志 (回车取消):${R}"
                read -e -p "选择: " act
                case $act in
                    1) systemctl restart sing-box && echo -e "${G}已重启${R}" ;;
                    2) systemctl stop sing-box && echo -e "${Y}已停止${R}" ;;
                    3) journalctl -u sing-box -n 30 --no-pager ;;
                esac
                read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${RED}输入无效${R}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 模块 3：内核调优
# ============================================================================
run_kernel_tune() {
    echo -e "${C}正在拉取 kernel-smart.sh 魔改内核脚本...${R}"
    URL="https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh"
    FILE="/tmp/kernel-smart.sh"
    if ! curl -fsSL --connect-timeout 10 "$URL" -o "$FILE"; then
        echo -e "${RED}下载失败！请检查网络。${R}"
        read -rs -n 1 -p "按任意键返回..."; return
    fi
    chmod +x "$FILE"
    echo -e "${Y}>>> 请在弹出的菜单中完成设置，完成后自动返回 <<<${R}"
    bash "$FILE"
    rm -f "$FILE"
    echo -e "${G}内核调优执行完毕！${R}"
    read -rs -n 1 -p "按任意键返回..."
}

ensure_forward() {
    if ! grep -q "^net.ipv4.ip_forward.*=.*1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
}

# ============================================================================
# 主菜单
# ============================================================================
ensure_forward

while true; do
    clear
    MYIP=$(get_my_ip)
    echo -e "${G}========================================${R}"
    echo -e "${G}   极致中转 & 落地管理面板 (T0)    "
    echo -e "${G}========================================${R}"
    echo -e "本机 IPv4: ${C}${MYIP}${R}"
    echo -e "${G}========================================${R}"
    echo -e "${Y}[ 中转机功能 ]${R}"
    echo -e "${G}1.${R} 添加内核态转发规则 (TCP 零损耗)"
    echo -e "${RED}2.${R} 删除内核态转发规则"
    echo -e "${H}3.${R} 查看当前转发规则"
    echo -e "${G}========================================${R}"
    echo -e "${Y}[ 落地机功能 ]${R}"
    echo -e "${C}4.${R} 进入 Sing-Box 节点管理模块"
    echo -e "${G}========================================${R}"
    echo -e "${Y}[ 系统优化 ]${R}"
    echo -e "${H}5.${R} 运行 kernel-smart.sh 内核调优"
    echo -e "${G}========================================${R}"
    echo -e "${H}0.${R} 退出"
    echo -e "${G}========================================${R}"
    
    read -e -p "请输入选择: " c
    case $c in
        1) add_rule; read -rs -n 1 -p "按任意键继续..." ;;
        2) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
        3) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
        4) sb_manage_menu ;;
        5) run_kernel_tune ;;
        0|"") exit 0 ;;
        *) echo -e "${RED}输入无效${R}"; sleep 1 ;;
    esac
done
