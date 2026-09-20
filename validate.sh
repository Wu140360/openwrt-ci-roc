#!/usr/bin/env bash
### 最终完整性验证：文件清单 + 权限 + 模拟合并 + 需求覆盖
set -uo pipefail
cd "$(dirname "$0")"

echo "========== 文件清单 =========="
find . -type f -not -path './.git/*' | sort

echo ""
echo "========== 可执行权限检查 =========="
for f in scripts/ZN-M2-script.sh files/etc/uci-defaults/99-znm2-defaults files/etc/init.d/nss-qos check-config.sh validate.sh; do
  [ -x "$f" ] && echo "  [✓] $f" || { echo "  [!] FIXING $f"; chmod +x "$f"; echo "  [✓] $f (fixed)"; }
done

echo ""
echo "========== YAML 语法 =========="
python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    yaml.safe_load(open(f)); print('  [✓]', f)
"

echo ""
echo "========== Bash 语法 =========="
for f in scripts/ZN-M2-script.sh files/etc/uci-defaults/99-znm2-defaults files/etc/init.d/nss-qos; do
  bash -n "$f" && echo "  [✓] $f"
done

echo ""
echo "========== 模拟 Build 时的配置合并（cat config ZN-M2 + General）并检查冲突 =========="
TMP="$(mktemp)"
cat configs/ZN-M2.config configs/General.config > "$TMP"
awk '
  /^CONFIG_[A-Za-z0-9_]+=[ym]$/ { en[$1]=1 }
  /^# CONFIG_.* is not set$/ { sub(/^# /,"",$0); sub(/ is not set$/,"",$0); dis[$0]=1 }
  /^CONFIG_[A-Za-z0-9_]+=n$/ { dis[$1]=1 }
  END {
    n=0
    for (s in en) if (dis[s]) { printf "  [CONFLICT] %s\n", s; n++ }
    if (n==0) print "  [✓] 无 enabled/disabed 冲突"
  }
' "$TMP"
rm -f "$TMP"

echo ""
echo "========== 需求覆盖（符号层面）=========="
python3 - <<'PY'
must = {
  "设备profile(zn_m2)": "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y",
  "NSS核心驱动": "CONFIG_PACKAGE_kmod-qca-nss-drv=y",
  "NSS qdisc(kmod,条件启用)": "# CONFIG_PACKAGE_kmod-qca-nss-qdisc is not set",
  "qca-nss-qdisc(用户态,条件启用)": "# CONFIG_PACKAGE_qca-nss-qdisc is not set",
  "SmartDNS主包": "CONFIG_PACKAGE_smartdns=y",
  "SmartDNS LuCI": "CONFIG_PACKAGE_luci-app-smartdns=y",
  "Aurora主题": "CONFIG_PACKAGE_luci-theme-aurora=y",
  "Aurora配置": "CONFIG_PACKAGE_luci-app-aurora-config=y",
  "ttyd": "CONFIG_PACKAGE_luci-app-ttyd=y",
  "DDNS": "CONFIG_PACKAGE_luci-app-ddns=y",
  "WireGuard(proto)": "CONFIG_PACKAGE_luci-proto-wireguard=y",
  "UPnP": "CONFIG_PACKAGE_luci-app-upnp=y",
  "KMS(vlmcsd)": "CONFIG_PACKAGE_luci-app-vlmcsd=y",
  "APK包管理": "CONFIG_PACKAGE_apk=y",
  "简体中文全局": "CONFIG_LUCI_LANG_zh_Hans=y",
  "关闭WiFi(ath11k)": "# CONFIG_PACKAGE_kmod-ath11k is not set",
  "关闭USB": "# CONFIG_PACKAGE_kmod-usb-core is not set",
  "关闭SQM(软QoS)": "# CONFIG_PACKAGE_sqm-scripts is not set",
  "关闭Passwall": "# CONFIG_PACKAGE_luci-app-passwall is not set",
  "关闭OpenClash": "# CONFIG_PACKAGE_luci-app-openclash is not set",
  "关闭Argon(只留Aurora)": "# CONFIG_PACKAGE_luci-theme-argon is not set",
}
import glob, re
text = "\n".join(open(f).read() for f in glob.glob("configs/*.config"))
ok = 0
for name, sym in must.items():
    if sym.startswith("# "):
        key = sym[2:]
        found = (key in text)
    else:
        found = bool(re.search(r"^" + re.escape(sym) + r"\s*$", text, re.M))
    print(f"  [{'✓' if found else '✗'}] {name}: {sym}")
    ok += found
print(f"\n  覆盖度: {ok}/{len(must)}")
PY

echo ""
echo "========== 引用完整性 =========="
echo -n "  ZN-M2.yml -> Build-OpenWrt.yml: "; [ -f .github/workflows/Build-OpenWrt.yml ] && echo "✓"
echo -n "  Build-OpenWrt.yml 读 diy_script input: "; grep -q 'diy_script:' .github/workflows/Build-OpenWrt.yml && echo "✓"
echo -n "  ZN-M2.yml 传 diy_script: "; grep -q 'diy_script: scripts/ZN-M2-script.sh' .github/workflows/ZN-M2.yml && echo "✓"
echo -n "  ZN-M2-script.sh 存在: "; [ -f scripts/ZN-M2-script.sh ] && echo "✓"
echo -n "  config_file 存在: "; [ -f configs/ZN-M2.config ] && echo "✓"
echo -n "  SmartDNS 配置存在: "; [ -f files/etc/smartdns/smartdns.conf ] && [ -f files/etc/config/smartdns ] && echo "✓"
echo -n "  NSS QoS 脚本存在: "; [ -f files/etc/init.d/nss-qos ] && [ -f files/etc/nss-qos/traffic-classify.nft ] && echo "✓"

echo ""
echo "========== validate done =========="
