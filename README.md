## 🛠️ 使用方法
請在您的 Debian / Ubuntu 伺服器終端機中，直接執行以下一鍵優化指令：

**📢 聰明的雙模操作指南：**
1. **第一次執行**：腳本會自動幫您下載 XanMod 支援 BBRv3 的頂級核心，並一鍵幫您把 TCP/UDP 緩衝優化配置好。
2. **手動重啟**：安裝完後請在命令列輸入 `reboot` 重啟伺服器。
3. **第二次執行（驗證）**：開機後，**再次執行完全相同的上方一行指令**，腳本就會自動切換為「狀態驗證模式」，直接在畫面上為您輸出精準的 BBRv3 深度診斷報告，確保一切完美對接！



```bash
bash <(curl -Ls https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh)
bash <(wget -qO- https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh)
