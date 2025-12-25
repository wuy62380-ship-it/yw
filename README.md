# YW Live Streaming Network Optimizer  
### Debian 11 / 12 / 13 · Smart Kernel Switch · BBR v2 Optimizer · Live Streaming Ready

本项目提供两大核心功能：

1. **智能内核切换（kernel-smart.sh）**  
   自动检测当前内核是否支持 BBR / BBR v2。  
   若不支持，将自动安装 Debian 官方原版内核（支持 BBR v2），并提示重启。

2. **智能 BBR 优化（auto-bbr.sh）**  
   针对直播推流场景优化 TCP 参数，并自动检测拥塞算法是否真正生效。  
   支持智能修复 + 自动 fallback（激进优先策略）。

适用于跨境直播、推流、弱网环境、跨境链路优化。

---

## 🚀 一键运行（推荐）

适用于 Debian 11 / 12 / 13：

```bash
wget -N --no-check-certificate "https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh" && chmod +x kernel-smart.sh && ./kernel-smart.sh
