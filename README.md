# 兆能M2 (zn_m2) OpenWrt 编译配置

## 硬件信息
- 设备：兆能M2 (zn_m2)
- 内存：硬改1GB
- 无WiFi（移除所有无线驱动）
- 无USB（移除所有USB相关）
- 用途：家庭主路由

## 功能清单
| 类别 | 功能 |
|------|------|
| NSS | 满血NSS 11.4，q6_region保持默认，qosify硬件QoS |
| WebUI | Aurora主题，中文，luci-app-opkg (apk包管理) |
| DNS | SmartDNS防污染(GitHub等)，预置DoH/DoT |
| 网络 | IPv4/IPv6双栈，DDNS(Cloudflare), WireGuard |
| QoS | qosify + qca-nss-qdisc (NSS加速) |
| 工具 | ttyd终端(zsh+tmux)，KMS，htop，iperf3，nmap等 |
| 系统 | ZRAM(LZ4)，BBR，sysctl性能优化，cpufreq |

## 使用方法
1. 推送本仓库到 GitHub
2. Actions → ZNM2-LibWrt → Run workflow
3. 等待编译完成，下载 Release 中的固件
4. 通过暗云uboot刷入

## 注意事项
- 首次启动需手动配置 SmartDNS 上游DNS
- qosify 默认关闭，填入带宽后启用
- DDNS 需填入 Cloudflare API Token
- WireGuard 可用 `wg-quick-peer` 命令快速配置
