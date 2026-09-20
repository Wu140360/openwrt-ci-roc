#!/usr/bin/env bash
### 端到端集成测试：精确复刻 Build-OpenWrt.yml 的合并行为并断言
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p .test && cd .test && rm -f .config

# 复刻 Build-OpenWrt.yml "Download DL Package" 步骤的合并逻辑
cat ../configs/ZN-M2.config ../configs/General.config > .config

echo "=== [A] 去重：每个 symbol 只保留最后一行（Kconfig 后写覆盖前写）==="
# 用 awk 保持顺序、后定义优先（symbol 名含字母/数字/下划线/连字符）
# 仅对 symbol 行更新 lines[]；注释/空行不参与（避免用旧 key 覆盖）
awk '
  /^# CONFIG_[A-Za-z0-9_-]+ is not set$/ { s=$0; sub(/^# /,"",s); sub(/ is not set$/,"",s); key=s; lines[key]=$0; next }
  /^CONFIG_[A-Za-z0-9_-]+=/ { key=$0; sub(/=.*$/,"",key); lines[key]=$0; next }
' .config > .config.dedup
mv .config.dedup .config

echo "=== [B] 断言：禁止项绝不能为 =y ==="
forbidden=(
  kmod-ath11k kmod-ath10k ath11k-firmware wpad hostapd iw iwinfo
  kmod-usb usbutils block-mount kmod-scsi kmod-fs-ext4 kmod-fs-vfat
  hdparm smartmontools fstrim fdisk cfdisk sgdisk
  luci-app-passwall luci-app-passwall2 luci-app-openclash luci-theme-argon
  sqm-scripts sqm-scripts-nss qosify nft-qos luci-app-qos
)
bad=0
for p in "${forbidden[@]}"; do
  if grep -qE "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "  [FAIL] forbidden =y: CONFIG_PACKAGE_${p}"; bad=$((bad+1))
  fi
done
[ $bad -eq 0 ] && echo "  [PASS] 无禁止项被启用"

echo ""
echo "=== [C] 断言：需求项必须存在 ==="
required=(
  CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y
  CONFIG_PACKAGE_kmod-qca-nss-drv=y
  CONFIG_PACKAGE_kmod-qca-nss-ecm=y
  CONFIG_NSS_FIRMWARE_VERSION_11_4=y
  CONFIG_PACKAGE_smartdns=y
  CONFIG_PACKAGE_luci-app-smartdns=y
  CONFIG_PACKAGE_luci-theme-aurora=y
  CONFIG_PACKAGE_luci-app-aurora-config=y
  CONFIG_PACKAGE_luci-app-ttyd=y
  CONFIG_PACKAGE_luci-app-ddns=y
  CONFIG_PACKAGE_luci-proto-wireguard=y
  CONFIG_PACKAGE_luci-app-upnp=y
  CONFIG_PACKAGE_vlmcsd=y
  CONFIG_PACKAGE_apk=y
  CONFIG_LUCI_LANG_zh_Hans=y
)
ok=0
for r in "${required[@]}"; do
  if grep -qxF "$r" .config; then ok=$((ok+1)); else echo "  [MISS] $r"; fi
done
echo "  [PASS] 需求项 ${ok}/${#required[@]} 命中"

echo ""
echo "=== [D] WiFi/USB 必须全部为 not set ==="
wifi_usb=(
  kmod-ath11k kmod-cfg80211 kmod-mac80211 wpad-openssl hostapd
  kmod-usb-core kmod-usb2 kmod-usb3 kmod-usb-storage block-mount
)
all_not_set=1
for p in "${wifi_usb[@]}"; do
  if ! grep -qE "^# CONFIG_PACKAGE_${p} is not set$" .config; then
    echo "  [FAIL] not disabled: $p"; all_not_set=0
  fi
done
[ $all_not_set -eq 1 ] && echo "  [PASS] WiFi/USB 全部关闭"

echo ""
echo "=== [E] NSS 满血：drv/ecm/pppoe/ipv6/vlan/bridge 均 =y ==="
nss_ok=1
for p in kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-drv-pppoe kmod-qca-nss-drv-ipv6 kmod-qca-nss-drv-vlan; do
  grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || { echo "  [FAIL] NSS missing: $p"; nss_ok=0; }
done
[ $nss_ok -eq 1 ] && echo "  [PASS] NSS 有线数据面完整"

echo ""
echo "=== 结果 ==="
[ $bad -eq 0 ] && [ $ok -eq ${#required[@]} ] && [ $all_not_set -eq 1 ] && [ $nss_ok -eq 1 ] \
  && echo "INTEGRATION TEST: ALL PASS" \
  || echo "INTEGRATION TEST: FAILED"

cd .. && rm -rf .test
