# 兆能 ZN-M2 OpenWrt 云编译配置（满血 NSS / 无 WiFi / 无 USB）

专为 **兆能 ZN-M2**（高通 IPQ6000 / qualcommax ipq60xx）家庭主路由打造的轻量化 OpenWrt 25.12 云编译配置，基于 [laipeng668/openwrt-ci-roc](https://github.com/laipeng668/openwrt-ci-roc) 流程改造，fork 到自己的仓库后可直接 GitHub Actions 一键编译。

> ⚠️ **硬件前提**：已硬改 **1GB RAM**（并刷好对应 CDT）、**无 USB 接口**、**已刷入第三方 U-Boot**。本配置完全不带 WiFi、不带 USB。

---

## 一、硬件与需求对照

| 项目 | 本机情况 | 固件策略 |
|---|---|---|
| 内存 | 硬改 1GB（可识别约 907MB） | ✅ 保留满血 NSS（q6_region 默认 85MB 不缩减） |
| 无线 | 无 / 不用 | ❌ 完全不带 WiFi（无 ath11k / wpad / hostapd） |
| USB | 无 | ❌ 完全不带 USB（无 kmod-usb-* / 外置文件系统） |
| 用途 | 家庭主路由 | ✅ IPv4 NAT + IPv6、DDNS、WireGuard、SmartDNS、QoS |
| 宽带 | 无 IPv4 公网，有 IPv6 | ✅ DDNS + IPv6 穿透，SmartDNS 解决 GitHub DNS 污染 |

---

## 二、固件核心特性

### ✅ 已开启（功能清单）
- **满血 NSS**：`NSS_FIRMWARE_VERSION_11_4`，q6_region 保持源码默认 85MB，**绝不缩减**
- **NSS QoS**：`sqm-scripts-nss`（nss-qdisc + cake）+ `luci-app-sqm` WebUI，满血 NSS 下完美支持
- **TurboACC 网络加速**：fast-classifier / shortcut-fe / nss-ifb
- **WebUI**：LuCI + **Aurora 主题**（唯一，不重复），全简体中文（含插件 i18n）
- **DNS**：SmartDNS（内置默认配置，**解决 GitHub DNS 污染**）+ dnsmasq
- **DDNS**：luci-app-ddns（Cloudflare / DNSPod / Aliyun 脚本）
- **WireGuard**：luci-proto-wireguard + luci-app-wireguard
- **KMS**：vlmcsd + luci-app-vlmcsd
- **TTYD 终端**：集成 bash / vim / nano / tmux / htop / ip / tcpdump / mtr / iperf3 等常用工具
- **基础网络**：IPv6(odhcpd/odhcp6c)、UPnP、WoL、ACME、nlbwmon、LLDP、IGMP proxy
- **稳定性**：cpufreq、autoreboot、watchcat、ZRAM swap、coremark
- **主机名**：`openwrt`，默认地址 `192.168.2.1`
- **包管理**：OpenWrt 25.12 默认 **apk**

### ❌ 已彻底剔除（防臃肿 / 降发热）
- 科学上网：passwall / passwall2 / openclash
- 下载/文件：aria2 / nginx / frp / lucky / openlist2 / gecoosac
- 通知/过滤：oaf / wechatpush / banip / arpbind
- 存储：samba4 / diskman / hd-idle（无 USB / 无硬盘）
- 主题：argon（仅保留 aurora，不重复）
- 全部其他设备 profile（仅保留 `zn_m2` 单设备，缩减固件体积）

---

## 三、目录结构

```
.
├── .github/
│   └── workflows/
│       ├── Build-OpenWrt.yml     # 通用构建核心（复用上游成熟流程）
│       └── ZN-M2.yml             # ★ ZN-M2 专属入口（手动触发）
├── configs/
│   ├── ZN-M2.config              # ★ 设备配置（目标/包选择/剔除，单设备 zn_m2）
│   └── General.config             # 通用配置（语言/i18n/签名/apk/全局开关）
├── scripts/
│   └── ZN-M2-script.sh           # ★ 定制脚本（主机名/主题/按需克隆 feeds/注入 SmartDNS）
├── files/
│   └── etc/uci-defaults/
│       └── 99-smartdns-defaults   # SmartDNS 内置默认配置（首次开机执行）
└── README.md
```

> 标记为 ★ 的是本次为 ZN-M2 **全新创建** 的文件，其余（Build-OpenWrt.yml）沿用项目成熟流程，仅修改了 `DIY_SCRIPT` 与缓存键引用。

---

## 四、使用方法（GitHub 即用）

1. 将本目录内容推送到你 fork 的仓库根目录（即 `Wu140360/openwrt-ci-roc`）：
   ```bash
   git clone https://github.com/Wu140360/openwrt-ci-roc.git
   cp -r zn_m2-configs/* openwrt-ci-roc/
   cd openwrt-ci-roc
   git add .
   git commit -m "feat: add ZN-M2 dedicated config (no-wifi, no-usb, full NSS)"
   git push
   ```
2. 进入仓库 **Actions** 页面 → 选择 **ZN-M2** workflow → **Run workflow**。
3. 编译完成后，在 **Releases** 页面下载产物（已自动将 `qualcommax` 重命名为 `nowifi`）。

### 刷机提示
- 产物路径示例：`bin/targets/qualcommax/ipq60xx/`（或重命名后的 `nowifi` 目录）
- 首次刷入建议先备份原厂分区，通过 U-Boot Web 刷 `*-factory.bin` 或 `*-sysupgrade.bin`
- 刷机后若未识别 1GB，需确认 CDT 已更新（硬改时必须刷对应内存的 CDT）

---

## 五、关键设计说明

### 1. q6_region 保持默认（满血 NSS）
源码 `ipq6018.dtsi` 默认预留 85MB 给 NSS/q6 核心。本配置**不修改该值**，理由：
- 已硬改 1GB RAM，内存充裕，无需牺牲 NSS 性能
- 完全不带 WiFi，ath11k 不再与 NSS 争抢内存
- 满血 NSS 是保证 QoS（nss-qdisc）、wireguard 卸载、NAT 加速的前提

### 2. NSS QoS 方案（sqm-scripts-nss）
这是 LibWrt / ImmortalWrt 生态在 IPQ60XX / IPQ807X 满血 NSS 下**唯一验证可用**的 QoS 方案：
- 内核态 `nss-qdisc` 直接挂载到 NSS 加速引擎，不回退到 CPU
- 用户态 `sqm-scripts-nss` 封装 cake / fq_codel 等队列规则
- LuCI 端通过 `luci-app-sqm` 配置（**注意：不是**传统的 `luci-app-sqm-nss`，那是旧分支）
- ⚠️ 使用时在 LuCI **网络 → SQM QoS** 中，将 `qdisc` 选为 `nss.qdisc`，`script` 选 `layer_cake.qos`

### 3. SmartDNS 内置配置（解决 GitHub DNS 污染）
`files/etc/uci-defaults/99-smartdns-defaults` 在首次开机时自动：
- 写入 `/etc/smartdns/smartdns.conf`：国内 DNS（223.5.5.5 / 114.114.114.114）+ 可信上游（1.1.1.1 / 8.8.8.8）分组
- 将 `github.com`、`githubusercontent.com`、`jsdelivr.net` 等域名强制走 `foreign` 组，规避 DNS 污染
- 修改 dnsmasq 上游为 `127.0.0.1#5353`，由 SmartDNS 接管递归
- 开机后可在 LuCI **服务 → SmartDNS** 二次微调

### 4. 配置文件合并顺序与"is not set"陷阱
`Build-OpenWrt.yml` 中合并顺序为：`ZN-M2.config` 在前，`General.config` 在后。
**后出现的 `is not set` 会覆盖前面的 `=y`**。因此：
- 所有"剔除项"统一维护在 `ZN-M2.config` 的"显式剔除"段落（单一事实源）
- `General.config` **不**对已启用的包声明禁用，避免误关功能

### 5. apk 包管理（OpenWrt 25.12）
- 源码默认已集成 apk，本配置通过 `CONFIG_PACKAGE_apk=y` 显式启用
- 固件内的软件源配置：`/etc/apk/repositories.d/distfeeds.list`
- 离线安装示例：`apk add --allow-untrusted *.apk`

---

## 六、验证清单（刷机后逐项核对）

- [ ] 系统 → 系统：主机名显示 `openwrt`，时区 Asia/Shanghai
- [ ] 系统 → 软件：包管理器为 **APK**
- [ ] LuCI 界面语言：简体中文，主题 Aurora
- [ ] 系统 → TurboACC：NSS 加速已启用
- [ ] 网络 → SQM QoS：选择 nss.qdisc + layer_cake，测试限速生效
- [ ] 网络 → 接口：IPv4 + IPv6 双栈正常
- [ ] 服务 → SmartDNS：启动成功，`nslookup github.com` 返回正确 IP
- [ ] 服务 → ddns：Cloudflare/DNSPod 正常更新
- [ ] 网络 → 接口 → WireGuard：握手成功
- [ ] 服务 → vlmcsd：KMS 激活可用
- [ ] 系统 → TTYD：可登录，bash / vim / tcpdump 等命令可用
- [ ] 系统 → 负载：空载内存占用合理，长时间高负载无重启
- [ ] 状态 → 概览：识别内存约 **907MB**（确认 1GB + NSS 预留后剩余）

---

## 七、故障排查

| 现象 | 排查方向 |
|---|---|
| 内存只识别 256MB | CDT 未更新，需刷硬改 1GB 对应 CDT |
| NSS QoS 不生效 | SQM 中 qdisc 是否选 `nss.qdisc`，`kmod-sched-nss` 是否加载 |
| SmartDNS 未分流 | 检查 `/etc/smartdns/smartdns.conf` 的 `nameserver /github.com/foreign` |
| GitHub 仍污染 | 确认 dnsmasq 上游已指向 127.0.0.1#5353，smartdns 服务运行 |
| 编译失败 | 查看 Actions 日志；多为 feeds 冲突，可 `./scripts/feeds update -i -a` 本地验证 |

---

## 参考
- 上游编译流程：https://github.com/laipeng668/openwrt-ci-roc
- LibWrt（NSS 方案）：https://github.com/laipeng668/LibWrt
- OpenWrt 25.12 apk 迁移：https://openwrt.org/docs/guide-user/additional-software/opkg-to-apk-cheatsheet
- 软件包解释（right.com.cn）：https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=8384897
