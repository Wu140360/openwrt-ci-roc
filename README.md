# 兆能 M2（ZN M2）OpenWrt 25.12 定制固件

面向家庭主路由的 **ZN M2 / 兆能 M2** 专用云编译仓库。设备为 IPQ6000，已硬改 **512MB 内存 + USB3.0**，并使用暗云 u-boot 扩容分区。

- 源码：`laipeng668/LibWrt`，分支 **`25.12-nss`**，Linux **6.12**
- 包管理：**apk**（OpenWrt 25.12）
- 设备 profile：仅 `qualcommax/ipq60xx` 的 **`zn_m2`**
- 默认地址：**`192.168.2.1`**，主机名 **`ZN-M2`**，默认无密码
- **无 WiFi**：不编译 ath11k 驱动/固件、hostapd/wpad，也不改 DTS 的 WiFi 节点
- **不改 q6_region**：保持 `ipq6018-512m.dtsi` 的 55MB（`0x3700000`），Roc-script 中 4 行缩容 sed 始终注释

## 一键云编译

在 GitHub 仓库的 **Actions → ZN-M2-LibWrt → Run workflow** 运行，分支选择 `3`。

工作流会调用 `.github/workflows/Build-OpenWrt.yml`，执行 `scripts/Roc-script.sh`、`make download`、`make -j$(nproc)`，最后上传 Artifact 并发布 `ZN-M2` Release。固件文件通常形如：

```text
libwrt-qualcommax-ipq60xx-zn_m2-squashfs-sysupgrade.bin
```

请以 Release/Artifact 中实际文件名为准。

## 刷机提示

1. 本固件假设已经刷好暗云 u-boot、扩容分区，并按 ZN M2 的 NAND 布局启动；不要使用其它机型或未扩容机器的镜像。
2. 首次从原厂/其它固件切换时，优先在 u-boot Web 恢复界面刷入 **sysupgrade** 镜像；不要刷写 u-boot 本身。
3. 保留 u-boot 环境变量和 MAC/校准分区。仓库不改 DTS、不改分区表、不改 q6_region。
4. 设备没有 WiFi 驱动，这是有意为之；请通过 LAN 口或已配置的 WAN 访问 LuCI。
5. 若从旧固件保留配置升级，建议先备份 `/etc/config`，升级后核对 WAN/LAN、防火墙和 QoS 模式。

## 功能与插件

| 类别 | 内容 |
|---|---|
| 主题 / 语言 | Aurora 主题 + Aurora 配置、简体中文 LuCI、各插件 `zh-cn` 翻译 |
| 满血 NSS（无 WiFi） | NSS drv、ECM、crypto、qdisc、IGS ingress、bridge/VLAN/PPPoE manager、nss-ifb、nssinfo |
| QoS | `sqm-scripts`、`sqm-scripts-nss`、`luci-app-sqm`、`luci-app-eqos`、自建 `luci-app-qos-switch` |
| USB | USB2/USB3、DWC3、UAS、ext4/vfat/exfat/ntfs3、block-mount、usbutils、lsblk、blkid、e2fsprogs、hd-idle |
| 网络 | PPPoE、DHCPv6/odhcpd、WireGuard、UPnP（miniupnpd nftables）、SmartDNS、lucky 万吉 |
| 系统/工具 | zram-swap(lz4)、ttyd、nlbwmon、KMS(vlmcsd)、watchcat、diskman、cpufreq、uhttpd、package-manager、tcpdump/iperf3/mtr/htop/btop/tmux/nano-full 等 |

**lucky 使用万吉版**：`lucky/Makefile` 的 `PKG_SOURCE` 通过 `$(PKG_VERSION)` 和 `$(LUCKY_ARCH)` 生成 `_wanji.tar.gz` 文件名，不写死版本；仓库内 `custom/lucky/` 若存在与 Makefile 同版本的本地包，会复制到 `dl/` 优先使用。万吉版已包含 DDNS、ACME、WOL、FTP/WebDAV 等能力，因此固件不再安装 ddns/acme/wol/samba4。

## QoS 三档一键切换

LuCI 菜单：**网络 → QoS 一键切换**。

| 模式 | 行为 | ECM |
|---|---|---|
| 关闭 | 停止 SQM/eqos，清理 qdisc | 恢复并保持开启 |
| 硬件简易 QoS | 使用 `sqm-scripts-nss` 的 `nss-zk.qos`，接口为逻辑 `wan`，上下行速率取页面值 | 保持开启 |
| 软件多功能 QoS | 选择 SQM+Cake 或 eqos（按 IP/MAC） | **先停止 ECM**，否则硬件加速会绕过 CPU 整形 |

说明：

- 当前 feed 的 `sqm-scripts-nss` 实际安装的是 **`nss-zk.qos`**（不是旧资料中的 `nss-rk.qos`）；切换脚本会优先使用 `nss-zk.qos`，并兼容旧文件名。
- 软件模式切换到硬件/关闭模式时会执行 `/etc/init.d/qca-nss-ecm start` 并重新 `enable`；切到软件模式时执行 `stop` + `disable`。这是依据 `qca-nss-ecm` 包的 init 脚本行为实现的。
- 带宽单位在 UCI/页面中为 **kbit/s**；eqos 内部会换算为 Mbit/s。
- `wan_dev=auto` 时从 `network.wan` 解析物理设备，仅用于状态展示和 tc 查询；SQM 实例使用逻辑接口 `wan`，兼容 PPPoE。
- 详细 SQM/eqos 参数可从切换页下方的按钮进入原插件页面配置。切换页会覆盖自己创建的 `sqm.qosswitch` 实例的速率、脚本和 qdisc 字段。

## 目录结构

```text
.github/workflows/Build-OpenWrt.yml   # 通用构建流程（保留）
.github/workflows/ZN-M2-LibWrt.yml    # ZN M2 入口
configs/ZN-M2.config                 # 仅 zn_m2，无 WiFi
configs/General.config               # NSS、QoS、USB、插件、简体中文
scripts/Roc-script.sh                # 配置注入、上游包拉取、lucky 万吉、自建包/rootfs
custom/package/luci-app-qos-switch/  # 自建 QoS 切换 LuCI 应用
custom/files/                        # rootfs 注入：sysctl、uci-defaults
custom/lucky/                        # （可选）本地 lucky 万吉包
```

## 运行时验证提示

以下项目依赖实机/完整编译环境，仓库只能做静态校验：

- `qca-nss-ecm` 的启停命令已经按 `nss-packages` 的 `qca-nss-ecm.init` 实现，但实际模块加载、debugfs 和 NSS 固件版本仍需在 M2 上确认。
- `nss-zk.qos` 的 ingress 使用 `ifb@wan`（不是 `nssifb`），状态页同时检查两者。
- 软件 Cake 模式关闭 ECM 后，请用 `tc -s qdisc show dev wan`、`nssinfo`/`nss_stats` 和实际限速测试确认没有硬件旁路。
- 首次启动后建议在 ttyd 运行 `qos-switch status`、`logread -e qos-switch`、`nss_stats` 检查。

## 上游与许可

构建脚本和配置基于 [laipeng668/openwrt-ci-roc](https://github.com/laipeng668/openwrt-ci-roc) 与 [laipeng668/LibWrt](https://github.com/laipeng668/LibWrt) 整理；NSS 包来自 `laipeng668/nss-packages`，SQM NSS 脚本来自 `qosmio/sqm-scripts-nss`，lucky 来自 `gdy666/luci-app-lucky`，Aurora 来自 `eamonxg`。本仓库保留上游 MIT 许可证，新增脚本按 MIT 发布。
