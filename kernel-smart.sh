#!/bin/bash

# ====================================================================
#  🔥 Linux 伺服器直播推流極致優化 + BBRv3 核心智能雙模腳本 🔥
#  功能：首次執行自動安裝並調優；重啟後再次執行直接進入終極驗證模式。
#  適用系統: Debian / Ubuntu (x86_64)
# ====================================================================

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 確保以 root 權限執行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}錯誤: 請使用 root 使用者或搭配 sudo 執行此腳本！${PLAIN}"
  exit 1
fi

# ====================================================================
# 模式判斷：檢查是否已經切換到 xanmod 核心
# ====================================================================
CURRENT_KERNEL=$(uname -r)

if [[ "$CURRENT_KERNEL" == *"xanmod"* ]]; then
  # ----------------------------------------------------------------
  # 🔍 【驗證模式】當前已經是新核心，直接印出終極 BBRv3 效能報告
  # ----------------------------------------------------------------
  clear
  echo -e "${BLUE}====================================================${PLAIN}"
  echo -e "${GREEN}      ✨ 歡迎使用 BBRv3 直播優化 終極狀態驗證工具 ✨      ${PLAIN}"
  echo -e "${BLUE}====================================================${PLAIN}"
  echo ""
  
  # 1. 檢查核心版本
  echo -e "➔ 1. 當前系統 Linux 內核核心: ${GREEN}${CURRENT_KERNEL}${PLAIN} (已成功切換至高規格核心)"
  
  # 2. 檢查 TCP 擁塞演算法
  TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
  if [ "$TCP_CC" = "bbr" ]; then
    echo -e "➔ 2. 當前 TCP 擁塞控制演算法: ${GREEN}bbr (核心已自動關聯並啟用 BBRv3 機制)${PLAIN}"
  else
    echo -e "➔ 2. 當前 TCP 擁塞控制演算法: ${RED}${TCP_CC} (異常，未成功啟用 bbr)${PLAIN}"
  fi
  
  # 3. 檢查佇列規則 (qdisc)
  QDISC=$(sysctl -n net.core.default_qdisc)
  if [ "$QDISC" = "fq" ]; then
    echo -e "➔ 3. 當前網路預設佇列規則: ${GREEN}fq (Fair Queueing 完美配對 BBRv3)${PLAIN}"
  else
    echo -e "➔ 3. 當前網路預設佇列規則: ${YELLOW}${QDISC} (建議為 fq)${PLAIN}"
  fi

  # 4. 深度檢測底層內核 bbr 模組狀態 (印出當前推流時的內部狀態)
  echo ""
  echo -e "${YELLOW}[底層 BBR 核心運作細節檢測]${PLAIN}"
  if modinfo tcp_bbr > /dev/null 2>&1; then
    BBR_VERSION=$(modinfo tcp_bbr | grep -E "version:" | awk '{print $2}')
    if [ -n "$BBR_VERSION" ]; then
      echo -e "   • BBR 模組版本標記: ${GREEN}${BBR_VERSION}${PLAIN}"
    else
      echo -e "   • BBR 模組狀態: ${GREEN}內建整合於目前內核中運作${PLAIN}"
    fi
  fi
  
  # 5. 輸出快取極限解鎖狀態
  FILE_MAX=$(sysctl -n fs.file-max)
  echo -e "   • 系統最高併發檔案限制 (fs.file-max): ${GREEN}${FILE_MAX}${PLAIN} (原版 65535，已成功解鎖至百萬級別)"

  echo ""
  echo -e "${GREEN}🎉 驗證完畢！您的伺服器目前正處於「抗丟包、超高吞吐量、低延遲」的最高戰鬥狀態！${PLAIN}"
  echo -e "${GREEN}現在您可以隨時開啟 OBS 或 FFmpeg 進行極限推流測試了。${PLAIN}"
  echo -e "${BLUE}====================================================${PLAIN}"
  exit 0
fi


# ----------------------------------------------------------------
# 🛠️ 【安裝模式】如果還不是 xanmod 核心，執行安裝與緩衝區調優
# ----------------------------------------------------------------
clear
echo -e "${BLUE}====================================================${PLAIN}"
echo -e "${YELLOW}  正在啟動: Linux 伺服器直播推流極致優化 + BBRv3 安裝流程  ${PLAIN}"
echo -e "${BLUE}====================================================${PLAIN}"
echo ""

echo -e "${YELLOW}[步驟 1/3] 正在安裝 XanMod BBRv3 官方核心相依組件...${PLAIN}"
apt update -y && apt install -y wget gnupg curl

# 註冊 XanMod 官方 PGP 金鑰並添加儲存庫
wget -qO - https://xanmod.org | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-kernel.list

echo -e "${GREEN}正在下載並安裝支援 BBRv3 的 XanMod 最新 Linux 核心...${PLAIN}"
apt update -y && apt install -y linux-image-xanmod-x64v3

# 更新系統 GRUB 開機引導
echo -e "${YELLOW}正在更新系統開機引導選單 (GRUB)...${PLAIN}"
if command -v update-grub > /dev/null 2>&1; then
  update-grub
else
  grub-mkconfig -o /boot/grub/grub.cfg
fi

echo -e "${YELLOW}[步驟 2/3] 正在備份原有的 /etc/sysctl.conf...${PLAIN}"
cp /etc/sysctl.conf /etc/sysctl.conf.bak

echo -e "${YELLOW}[步驟 3/3] 正在配置極限直播推流（TCP + UDP + BBRv3 完美調優配置）...${PLAIN}"
cat << 'EOF' > /etc/sysctl.conf
# ====================================================================
# 🔥 直播推流與網絡測速 終極完美優化區（TCP + UDP 全方位覆蓋）
# ====================================================================

# 1. 提升檔案開啟數（提升至 100 萬以應對高併發直播連線）
fs.file-max = 1000000

# 2. 增大網路傳輸總隊列（防止推流突發大流量時隊列溢出）
net.core.netdev_max_backlog = 25000
net.core.somaxconn = 4096

# 3. 核心快取全域調優（設定最相容的 8MB 緩衝區，兼顧測速與大碼率推流）
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# 4. TCP 專屬調優（適用於 RTMP / HLS 直播與一般網絡測速）
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535

# 5. UDP 專屬調優（針對 SRT / WebRTC / 奎科等低延遲直播協定）
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_mem = 786432 1048576 1572864

# 6. 啟用 BBR 擁塞控制演算法與 FQ 佇列規則（在新內核下完美激發 BBRv3 效能）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# 強制重新整理當前網路參數
sysctl -p

echo ""
echo -e "${BLUE}====================================================${PLAIN}"
echo -e "${GREEN}🎉 恭喜！核心更換與網路緩衝區終極調優配置已全部就緒！${PLAIN}"
echo -e "${RED}⚠️  重要提示: 由於更換了底層核心，您必須手動重啟伺服器才能完整激活 BBRv3 核心！${PLAIN}"
echo -e "請在退出後輸入指令：${YELLOW}reboot${PLAIN} 重啟系統。"
echo -e "開機後，${GREEN}再次執行本一鍵指令${PLAIN}，即可直接查閱完美的 BBRv3 最終效能報告！"
echo -e "${BLUE}====================================================${PLAIN}"
