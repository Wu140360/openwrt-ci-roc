# 兆能 M2（zn_m2）OpenWrt 固件编译配置

> 基于 [laipeng668/openwrt-ci-roc](https://github.com/laipeng668/openwrt-ci-roc) 云编译项目，
> 源码 [LibWrt `25.12-nss`](https://github.com/laipeng668/LibWrt)（IPQ60XX / 6.12 内核 / 满血 NSS）

## 设备背景

- **机型**：兆能 M2（Zn M2，芯片 IPQ6018 / IPQ6000）
- **内存**：硬改 1 GiB（原厂 256 MiB）
- **无 USB、无 WiFi 无线硬件**（纯有线路由）
- **用途**：家庭主路由，宽带**无 IPv4 公网、有 IPv6**
- **Bootloader**：已刷暗云 U-Boot

## 固件设计原则（对应需求逐条）

| 需求 | 实现方式 |
|------|----------|
| 完全不带 WiFi、不带 USB | 关闭 `ath11k`/`cfg80211`/`mac80211`/`hostapd`/`wpad` 及全部 USB kmod；uci-defaults 兜底 `wifi down` |
| 满血 NSS，**不缩减 q6_region**，保持默认 | 保留 `kmod-qca-nss-drv` 全套；DTS reserved-memory **不动**；仅校验 1G memory 节点 |
| 硬件 QoS（不要软 QoS） | **唯一路径**：NSS 引擎卸载 NAT(数据面) + `tc` HTB 分类(控制面)；`nss-qos` 脚本运行时检测 `nss_qdisc` 模块，存在则硬件卸载，否则软件 HTB 兜底 |
| **设备镜像兼容兜底** | 同时选中 `DEVICE_zn_m2` 与 `DEVICE_cmiot_ax18`（兆能 M2 与 CMCC AX18 同源，部分源码树仅提供后者），确保一定产出可用镜像 |
| 相同功能不重复 | QoS 仅 NSS qdisc（剔除 SQM/qosify/nft-qos/luci-app-qos）；DNS 仅 SmartDNS（剔除 adblock/banip） |
| 注重性能 / 稳定性 | zram-swap、autocore、coremark、ethtool、iperf3、tcpdump 等诊断工具 |
| WebUI + Aurora 主题 | `luci-theme-aurora` + `luci-app-aurora-config`（**唯一主题，弃用 Argon**） |
| 插件带 WebUI 设置 | ddns、upnp、vlmcsd、ttyd、smartdns、acme 均带 LuCI app |
| i18n 简体中文（含插件） | `CONFIG_LUCI_LANG_zh_Hans=y` + 各 `luci-i18n-*-zh-cn` |
| 路由器基础网络齐全 | firewall4/nftables、PPPoE、IPv6(RA/DHCPv6)、DHCP、DDNS、UPnP、KMS、WireGuard |
| ttyd 终端 + 常用工具 | ttyd + `/usr/bin/network-tools` + `profile.d` 别名（netstatus/dnstest/nsstest/qosstatus/bandtest） |
| 包管理（25.12 = APK） | `CONFIG_PACKAGE_apk=y`，弃用 opkg |
| 设备名 openwrt | uci-defaults 设置 `hostname=openwrt`、LAN `192.168.2.1`、时区 Asia/Shanghai |
| DDNS + WireGuard | `luci-app-ddns`（含 cloudflare）+ `luci-proto-wireguard`（IPv6 AAAA 友好） |
| **无科学上网** | 全量剔除 passwall/passwall2/openclash/shadowsocks/v2ray/xray/trojan/sing-box/naiveproxy 等 |
| 解决 GitHub DNS 污染（SmartDNS） | 国内默认组 + `foreign` 加密组（Cloudflare/Google DoT+DoH），github/raw/ jsDelivr/npm/PyPI/Go/Rust 走 foreign |

## 目录结构

```
configs/
├── ZN-M2.config        # 设备层：zn_m2/cmiot_ax18 双 profile、NSS 满血、关闭 WiFi/USB、QoS、1G 内存
└── General.config       # 通用层：APK、LuCI、Aurora、i18n、SmartDNS、基础服务、剔除代理

scripts/
└── ZN-M2-script.sh     # 设备专属 DIY 脚本（对标 Roc-script.sh）：hostname、固件署名、按需克隆包

.github/workflows/
├── Build-OpenWrt.yml   # 通用构建流程（向后兼容增强：diy_script / general_config inputs，默认 Roc-script.sh / General.config）
└── ZN-M2.yml           # 构建入口：调用 Build-OpenWrt，传入 ZN-M2 参数

files/                  # 覆盖层（随固件打包，首次启动由 uci-defaults 应用）
├── etc/uci-defaults/99-znm2-defaults   # 默认设置：hostname/网络/DNS协调/QoS/ttyd/主题/关WiFi
├── etc/config/smartdns                 # SmartDNS UCI（redirect=none，直连 53）
├── etc/smartdns/smartdns.conf          # SmartDNS 主配置：分组分流规则
├── etc/init.d/nss-qos                  # NSS QoS 服务（运行时检测 nss_qdisc，加载 tc 规则）
└── etc/nss-qos/traffic-classify.nft    # nftables 流量分类（打 fwmark 0x10/0x20/0x30）
```

## 使用方法（GitHub Actions）

1. 将本目录内容覆盖合并到你的 fork 仓库（`Wu140360/openwrt-ci-roc`）
2. GitHub → Actions → 选择 **ZN-M2** workflow → `Run workflow`
3. 构建完成后，固件产物在 Release `ZN-M2`：`*squashfs-sysupgrade.bin` / factory

### 首次编译建议（分阶段验证，便于定位问题）

构建系统会自动按以下顺序验证，也可手动分步：
1. **基线**：确认 `zn_m2` profile 被选中、分区/U-Boot 正常 → 看构建日志 `diffconfig`
2. **NSS**：`lsmod | grep nss`、`cat /proc/net/nss/*`
3. **QoS**：`tc -s qdisc show`、`tc -s class show`（LAN 侧应有 HTB 分类）
4. **DNS**：`nslookup github.com 127.0.0.1`、`dig +short raw.githubusercontent.com`
5. **应用**：Aurora 主题、DDNS、WireGuard、UPnP、KMS、ttyd 页面

## 关键验证清单（开机后）

```sh
# 1. 设备名 + 内存（应识别 ~907-1008 MiB，且不破坏 reserved-memory）
uci get system.@system[0].hostname     # openwrt
free -m

# 2. NSS 是否加载（应见到 nss-drv / nss-qdisc）
lsmod | grep -i nss

# 3. 硬件 QoS（应见到根 HTB + 3 个 class）
tc -s qdisc show dev br-lan
tc -s class show dev br-lan

# 4. SmartDNS 抗污染（github 应解析到正确 IP，走 foreign 组）
nslookup github.com 127.0.0.1
nslookup www.baidu.com 127.0.0.1      # 走国内组

# 5. 端口监听（53=SmartDNS，dnsmasq 仅 DHCP 不监听 53）
netstat -tulpn | grep -E ':53|:67'
```

## 重要注意事项

1. **q6_region / reserved-memory**：**严禁缩减**。本配置保持 LibWrt 默认，仅做内存容量核对。
2. **暗云 U-Boot**：请确认当前分区布局与 `libwrt-qualcommax-ipq60xx-*` 产物匹配；
   `rename_qualcommax_to_nowifi=false`（不改产物文件名），以保 U-Boot 兼容。
3. **设备 profile 兜底**：同时选中 `zn_m2` 与 `cmiot_ax18`（兆能 M2 与 CMCC AX18 同源，
   社区源码常以 cmiot_ax18 为名）。若 LibWrt 25.12-nss 只有其一，另一个 `is not set`
   会自动失效，**保证一定能产出可用镜像**。构建日志看 `diffconfig` 确认生效 profile。
4. **NSS QoS 卸载机制**：
   - **数据面(NAT/路由)** 由 `kmod-qca-nss-drv` + ECM **硬件卸载** —— "满血 NSS"核心，已启用；
   - **QoS 调度** 在 tc(HTB) 层，`init.d/nss-qos` 运行时尝试加载 `nss_qdisc` 模块做卸载；
     若未编译该模块，自动退化为软件 HTB（仍可用）；
   - `kmod-qca-nss-qdisc` / `qca-nss-qdisc` 设为 `is not set`（条件启用），避免包名不存在导致编译失败。
   - 验证：`tc -s qdisc show dev br-lan`、`lsmod | grep nss`、对比高吞吐下 CPU 占用。
5. **SmartDNS 加密上游**：若运营商封锁 853/443，可把 `foreign` 组改为阿里/腾讯 DoT 实测。

## 需求完成度自检

- [x] 完全不带 WiFi、不带 USB
- [x] 满血 NSS，q6_region 保持默认不缩减
- [x] 硬件 NSS QoS（非软 QoS），唯一路径
- [x] 功能去重（QoS/DNS/代理各只保留一个）
- [x] WebUI（Aurora）+ 插件 Web 设置
- [x] i18n 简体中文（全局 + 插件）
- [x] 基础网络齐全（防火墙/NAT/PPPoE/IPv6/DHCP/DDNS/UPnP）
- [x] 诊断/配置工具（iperf3/tcpdump/ethtool/ss 等）+ ttyd 集成
- [x] APK 包管理（25.12）
- [x] 设备名 openwrt（LAN 192.168.2.1）
- [x] DDNS + WireGuard（IPv6 友好）
- [x] 无科学上网（全量剔除）
- [x] SmartDNS 内置抗污染（GitHub 等走 foreign 加密组）
- [x] KMS（vlmcsd + LuCI）
- [x] 轻量化（剔除 USB/音频/视频/打印/Docker/Samba/广告过滤冗余）
- [x] 剔除仓库内其他设备镜像（CONFIG_TARGET_MULTI_PROFILE=n，仅 zn_m2 + cmiot_ax18 兜底）
