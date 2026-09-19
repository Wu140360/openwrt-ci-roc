# 兆能M2 (zn_m2) OpenWrt 云编译配置

## 硬件信息
- **CPU**: Qualcomm IPQ6000 (4x Cortex-A53 1.2GHz + NPU 1.5GHz)
- **内存**: 1GB DDR3 (硬件改装, 原厂256MB)
- **闪存**: 128MB SPI-NAND
- **网络**: 4x Gigabit Ethernet (1 WAN + 3 LAN)
- **平台**: qualcommax/ipq60xx
- **Bootloader**: 暗云 u-boot

## 固件特性
- ✅ **完全无WiFi** - 去除所有无线驱动和固件, 纯有线
- ✅ **完全无USB** - 去除所有USB相关包
- ✅ **满血NSS** - 保持默认q6_region, NSS 11.4固件, 全功能offload
- ✅ **NSS硬件QoS** - qosify + qca-nss-qdisc, 硬件级流量管理
- ✅ **SmartDNS** - 内置GitHub DNS防污染规则, 国内外分流
- ✅ **DDNS** - Cloudflare支持 (IPv4 + IPv6)
- ✅ **WireGuard** - VPN支持
- ✅ **KMS** - 激活服务 (默认启用, 端口1688)
- ✅ **TTYD终端** - 集成常用诊断工具别名
- ✅ **Aurora主题** + **简体中文**
- ✅ **性能优化** - BBR + TCP调优 + ZRAM + schedutil

## 文件结构
```
├── .github/workflows/
│   ├── Build-OpenWrt.yml      # 主编译工作流 (被调用)
│   ├── ZNM2-LibWrt.yml        # ZNM2 编译入口 (手动触发)
│   └── Build-Packages.yml     # SDK 独立包编译
├── configs/
│   ├── znm2.config            # 主设备配置 (target/device)
│   └── General.config          # 通用配置 (packages/features)
├── scripts/
│   └── Roc-script.sh          # DIY自定义脚本 (SmartDNS预设等)
└── README.md
```

## 使用方法

### GitHub Actions 云编译
1. Fork 本项目到自己的 GitHub 账号
2. 进入 Actions 标签页, 选择 `ZNM2-LibWrt`
3. 点击 `Run workflow`, 选择 SDK 版本 (推荐 25.12)
4. 等待编译完成 (约1-2小时)
5. 在 Release 页面下载固件

### 本地编译
```bash
# 克隆 LibWrt 源码
git clone -b 25.12-nss --depth 1 https://github.com/laipeng668/LibWrt.git libwrt
cd libwrt

# 复制配置文件
cp /path/to/znm2.config .config
cat /path/to/General.config >> .config

# 运行自定义脚本
chmod +x /path/to/Roc-script.sh
/path/to/Roc-script.sh

# 编译
make defconfig
make -j$(nproc) V=s
```

## 默认设置
- **管理地址**: 192.168.2.1
- **主机名**: openwrt
- **默认密码**: 空 (首次登录设置)
- **时区**: Asia/Shanghai

## 首次配置建议
1. 登录后设置 root 密码
2. SmartDNS 默认已启用, 无需额外配置即可解决GitHub DNS污染
3. qosify QoS 默认**未启用**, 需在 LuCI → 服务 → QoSify 中开启并填入实际带宽
4. DDNS 默认**未启用**, 需在 LuCI → 服务 → Dynamic DNS 中配置 Cloudflare API Token
5. WireGuard 需手动创建接口和 Peer
6. KMS 默认启用, 局域网设备可将激活服务器设为 192.168.2.1:1688

## NSS QoS 说明
本项目使用 **qosify** 方案, 基于 **qca-nss-qdisc** 实现:
- qosify 是 OpenWrt 官方维护的现代 QoS 框架
- 通过 NSS 硬件队列实现加速, CPU 占用极低
- 支持 autorate (自动带宽检测), 无需手动调参
- 相比传统 SQM, NSS QoS 在千兆带宽下几乎零开销

启用方法 (LuCI):
1. 进入 服务 → QoSify
2. 开启服务, 填入实际上下行带宽 (如 1000/100 mbit)
3. 选择接口 (默认 wan)
4. 保存应用

## SmartDNS 规则说明
预设配置已包含:
- **国内DNS**: 阿里DNS (223.5.5.5) + DNSPod (119.29.29.29)
- **国际DNS**: Google DNS + Cloudflare DNS (DoH/DoT)
- **GitHub全系列域名** → 强制走国际DNS, 使用TCP查询 (防UDP污染)
- **国内常用域名** → 走国内DNS (加速)

如需添加其他域名规则, 编辑 `/etc/config/smartdns` 中的 `domain-rule` 段。

## 注意事项
- 固件默认不含WiFi, 如需WiFi请使用原厂或添加 ath11k 驱动
- 1GB 内存已配置 ZRAM 交换, 无需担心内存不足
- 默认 IP 为 192.168.2.1 (避免与光猫 192.168.1.1 冲突)
- 刷机前请备份原厂固件和 ART/board_data 分区

## 免责声明
本项目仅供学习研究使用, 不对使用本固件造成的任何损失承担责任。
请遵守国家相关法律法规, 不得用于商业用途。
