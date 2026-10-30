# 兆能 M2（ZN-M2）OpenWrt 25.12 满血 NSS 精简固件

本仓库是 [openwrt-ci-roc](https://github.com/laipeng668/openwrt-ci-roc) 的定制分支，**只为一个设备**
编译固件：**兆能 M2（ZN-M2）**。固件完全不带 WiFi，保留满血有线 NSS 加速，使用 aurora 主题与
全简体中文 LuCI。

## 设备与源码

| 项 | 值 |
|---|---|
| 设备 | 兆能 M2（ZN-M2），Qualcomm IPQ6000（4×A53 1.2GHz + NPU），aarch64_cortex-a53 |
| 硬件 | 硬改 512M RAM + USB3.0；已刷暗云 uboot 扩容分区 |
| OpenWrt | LibWrt `25.12-nss` 分支（OpenWrt 25.12 稳定版 + 满血 NSS，内核 6.12） |
| 源码 | <https://github.com/laipeng668/openwrt-6.x.git> |
| 目标 | `qualcommax` / `ipq60xx` / profile `zn_m2` |
| 固件格式 | UBI（`Device/FitImage` + `Device/UbiFit`），factory.ubi / sysupgrade.bin |
| 包管理 | `apk`（OpenWrt 25.12 起） |
| 默认地址 | `192.168.2.1`，默认无密码 |

## 如何触发编译

1. 打开本仓库的 **Actions** 页面；
2. 选择工作流 **IPQ60XX-LibWrt**；
3. 在右侧 **Run workflow** 中把分支切换为 **`2`**（本定制分支），再点击运行；
4. 编译完成后固件会发布到 **Releases**（tag：`IPQ60XX`），也可在本次运行页面下载 Artifact。

> 也可以把仓库默认分支设为 `2`，这样 Actions 页面默认就运行本分支。
> 工作流只编译 `IPQ60XX-LibWrt`，其余机型的工作流与配置已从本分支移除。

## 主要功能

### 系统 / WebUI
- aurora 主题（`luci-theme-aurora` + `luci-app-aurora-config`），全简体中文（`zh_Hans`）
- 包管理界面 `luci-app-package-manager`（apk）、uhttpd、firewall、ttyd Web 终端
- CPU 调频 `luci-app-cpufreq`（默认 `schedutil`，保留最高频可用）、autoreboot、watchcat、hd-idle
- zram-swap（LZ4）、smartmontools + drivedb、hdparm、zoneinfo-asia、openssh-sftp-server
- 常用命令行工具：nano-full、htop、tmux、dmesg、ip-full、ip-bridge、ethtool-full、tcpdump-mini、
  iperf3、mtr、curl、ca-certificates、jq、strace、lsblk、fstrim、tune2fs、fdisk、cfdisk、sgdisk、
  block-mount

### 网络
- PPPoE（ppp / kmod-pppoe / kmod-pppox / kmod-slhc / pppoe-discovery / luci-proto-ppp）
- IPv6（odhcp6c / odhcpd-ipv6only / luci-proto-ipv6）、FullCone NAT（`kmod-nft-fullcone`）
- UPnP（`luci-app-upnp` + `miniupnpd-nftables`）、WireGuard、omcproxy（IPTV 组播）
- 不安装 6in4/6rd/6to4/dslite/map、mwan3、macvlan

### 满血 NSS（仅有线）
- ECM + 有线 NSS 子模块：`kmod-qca-nss-drv`、`kmod-qca-nss-ecm`、`-qdisc`、`-igs`、`-bridge-mgr`、
  `-pppoe`、`-tun6rd`、`-gre`、`-l2tpv2`、`-map-t`、`-clmapmgr`、`-tunipip6`、`kmod-nss-ifb`
- `NSS_DRV_*_ENABLE`（BRIDGE/IPV6/VIRT_IF/PPPOE/VLAN/LAG/TUN6RD/GRE/L2TP/MAPT/CLMAP/TUNIPIP6/SHAPER/IGS）
  在 nss_packages 中默认全部为 `n`，配置里已显式置 `y`，否则 ECM 等子模块会因依赖不满足被丢弃
- `kmod-qca-nss-drv-match` 依赖 `NSS_DRV_WIFIOFFLOAD_ENABLE`（WiFi offload 分类器），无 WiFi 固件不启用
- NSS 固件版本固定 11.4；`q6_region` **保持源码默认预留**，未做任何缩减
- 未启用 `CONFIG_FEED_nss_packages`（NSS 驱动随 LibWrt 的 nss_packages feed 参与构建）

### 完全不带 WiFi
- 不编译 `kmod-ath11k*`、`ath11k-firmware-ipq6018`、`ipq-wifi-zn_m2`、`wpad*`、`hostapd-common`、
  `kmod-qca-nss-drv-wifi-meshmgr`、`luci-app-wifischedule`
- `configs/IPQ60XX.config` 中已删除 `CONFIG_ATH11K_*`

### 应用
- KMS：`luci-app-vlmcsd` + `vlmcsd`
- SmartDNS：`luci-app-smartdns` + `smartdns`
- lucky **万吉（wanji）3.5.0**：`luci-app-lucky` + `lucky`，二进制由构建脚本替换为官方
  `lucky_3.5.0_Linux_arm64_wanji.tar.gz`（aarch64，含 FileBrowser / Rclone）。
  因此不再重复安装 rclone、filebrowser、webdav、FTP、DDNS、ACME 等插件。
- EasyTier：`luci-app-easytier` + `easytier-noweb`（官方预编译二进制，不编译 Rust）
- 流量统计：`luci-app-nlbwmon` + `nlbwmon`（NSS 加速会漏统计，仅作近似账本）
- 文件共享：`luci-app-samba4` + `samba4-server`
- 明确不装：代理类（passwall/openclash 等）、frp、ddns、acme、wol、diskman、aria2/ariang、
  nginx、banip、arpbind、usb-printer、wechatpush、coremark、btop 等

### USB3.0（硬改）
- `kmod-usb-core`/`usb2`/`usb3`/`usb-dwc3`/`usb-dwc3-qcom`、`usb-storage` + UAS/extras
- 文件系统：ext4 / vfat / msdos / exfat / ntfs3 / f2fs，`usbutils`、`block-mount`
- USB 网卡：rtl8152 / asix / cdc-ether / rndis；USB 串口：option / ch341 / cp210x / pl2303 / ftdi

## QoS：三态一键切换（重要）

ECM 把流转交 NSS 固件后不再经过 Linux qdisc，**软件 QoS 与 NSS 硬件加速不能同时生效**。
因此本固件提供三态互斥模式，LuCI 菜单位置：**网络 → QoS 模式**（`/usr/sbin/qos-switch`）：

| 模式 | 行为 | 适用 |
|---|---|---|
| `off`（默认） | 停 qosify/sqm，卸载 `nss-ifb`，启动 ECM，满血 NSS 硬件加速 | 绝大多数场景 |
| `nss` | 启动 ECM，加载 `nss-ifb` 并在 `nssifb`/WAN 上挂 `nsstbl` + `nssfq_codel` | 需要简单限速整形（实验） |
| `qosify` | 停 ECM、卸载 `nss-ifb`，用 `qosify`（eBPF + CAKE，diffserv4）做软件整形 | 需要 IP/端口/DSCP 级精细管理 |

- 硬件模式仅支持 `fq_codel`，**没有 CAKE、没有多级分类**，上游仅验证 IPQ807x，IPQ60xx 属未测试，
  因此定位为“硬件简易 QoS（实验）”，不要承诺稳定。
- 软件模式 `qosify` 关闭 ECM 后 NSS 不再加速，吞吐会下降到 CPU 水平，这是机制决定的取舍。
- 页面可查看当前 `tc -s qdisc show` 状态；命令行：`qos-switch off|nss|qosify|apply|status`。

## 性能 / 稳定 / 发热

- `files/etc/uci-defaults/99-znm2-tuning`：关闭 `flow_offloading` / `flow_offloading_hw`（与 NSS 互斥）、
  时区 `Asia/Shanghai`、cpufreq `schedutil`、启用 ttyd、QoS 默认 `off`
- `files/etc/sysctl.d/99-znm2.conf`：`nf_conntrack_max=131072`、BBR、`netdev_max_backlog=4096`、
  收发缓冲与 `fs.file-max` 适度提高
- 不开启 packet steering / irqbalance / 软件或硬件 flow offloading

## 目录结构

```
configs/IPQ60XX.config          仅 zn_m2 的设备配置（含 NSS 固件 11.4）
configs/General.config          通用包选择（无 WiFi、NSS、USB、QoS、中文语言包）
scripts/Roc-script.sh           feeds 前的定制脚本（主题、lucky 万吉替换、EasyTier、qos-switch、files 注入）
packages/qos-switch/            三态 QoS 切换包（脚本 + init + LuCI + 中文 po）
packages/lucky-wanji/           lucky 万吉 3.5.0 aarch64 官方离线包（构建时校验 sha256）
files/                          根文件系统覆盖层（uci-defaults、sysctl）
.github/workflows/IPQ60XX-LibWrt.yml   唯一工作流（Build-OpenWrt.yml 为公共实现）
```

## 注意事项

1. 本分支只适配兆能 M2，不要用于其他 IPQ60xx 机型。
2. 固件不带 WiFi 是刻意选择：没有 ath11k 驱动、无线固件与 hostapd，LuCI 中也不会出现无线菜单。
3. lucky 使用万吉版二进制，升级 lucky 时请保持 `lucky_*_wanji.tar.gz` 来源，否则会退回标准版（无
   FileBrowser/Rclone）。
4. NSS 只加速有线转发；WireGuard、qosify 等走 CPU，属预期行为。
5. `firewall4` 硬依赖 `kmod-nft-offload`（只是提供 netfilter flowtable 能力），固件保留该模块，但
   `flow_offloading` / `flow_offloading_hw` 已在 `99-znm2-tuning` 中关闭，不会与 NSS 争抢转发路径。
6. 首次刷机请使用 factory.ubi（uboot 扩容分区），升级使用 sysupgrade.bin。
