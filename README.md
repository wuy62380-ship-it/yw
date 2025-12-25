# YW Live Streaming Network Optimizer  
### Debian 11 / 12 / 13 · Smart Kernel Switch · BBR v2 Optimizer · Live Streaming Ready


## 🚀 一键运行（推荐）

适用于 Debian 11 / 12 / 13：
验证 BBR 是否生效
sysctl net.ipv4.tcp_congestion_control
输出应为：bbr
验证 fq：sysctl net.core.default_qdisc
输出应为：fq


```bash
bash <(curl -Ls https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh)
bash <(wget -qO- https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh)
