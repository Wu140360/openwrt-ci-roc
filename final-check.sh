#!/usr/bin/env bash
### 最终校验：模拟 Build-OpenWrt.yml 实际合并行为（cat device + general），做完整体检
set -uo pipefail
cd "$(dirname "$0")"

echo "########## 0. 元数据 ##########"
echo "文件总数: $(find . -type f -not -path './.git/*' | wc -l)"
echo ""

echo "########## 1. 模拟 Build 合并（cat ZN-M2.config General.config）##########"
TMP="$(mktemp)"
cat configs/ZN-M2.config configs/General.config > "$TMP"

echo "--- 1a. enabled/disabed 冲突检测 ---"
awk '
  /^CONFIG_[A-Za-z0-9_]+=[ym]$/ { en[$1]=1 }
  /^# CONFIG_.* is not set$/ { s=$0; sub(/^# /,"",s); sub(/ is not set$/,"",s); dis[s]=1 }
  /^CONFIG_[A-Za-z0-9_]+=n$/ { dis[$1]=1 }
  END {
    n=0
    for (s in en) if (dis[s]) { printf "  [CONFLICT] %s\n", s; n++ }
    if (n==0) print "  [OK] 无冲突"
  }
' "$TMP"
echo ""

echo "--- 1b. 需求覆盖（合并后） ---"
export TMP_PATH="$TMP"
python3 - <<'PY'
import os, re
tmp = os.environ["TMP_PATH"]
must = [
    ("设备profile-zn_m2", "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y"),
    ("兜底cmiot_ax18(默认关闭)", "# CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_cmiot_ax18=y"),
    ("单profile(MULTI_PROFILE=n)", "CONFIG_TARGET_MULTI_PROFILE=n"),
    ("NSS drv", "CONFIG_PACKAGE_kmod-qca-nss-drv=y"),
    ("NSS ecm", "CONFIG_PACKAGE_kmod-qca-nss-ecm=y"),
    ("NSS qdisc(条件,not set)", "# CONFIG_PACKAGE_kmod-qca-nss-qdisc is not set"),
    ("SmartDNS", "CONFIG_PACKAGE_smartdns=y"),
    ("SmartDNS LuCI", "CONFIG_PACKAGE_luci-app-smartdns=y"),
    ("Aurora", "CONFIG_PACKAGE_luci-theme-aurora=y"),
    ("Aurora-config", "CONFIG_PACKAGE_luci-app-aurora-config=y"),
    ("ttyd", "CONFIG_PACKAGE_luci-app-ttyd=y"),
    ("DDNS", "CONFIG_PACKAGE_luci-app-ddns=y"),
    ("WireGuard(proto)", "CONFIG_PACKAGE_luci-proto-wireguard=y"),
    ("UPnP", "CONFIG_PACKAGE_luci-app-upnp=y"),
    ("KMS(vlmcsd)", "CONFIG_PACKAGE_luci-app-vlmcsd=y"),
    ("APK", "CONFIG_PACKAGE_apk=y"),
    ("zh_Hans", "CONFIG_LUCI_LANG_zh_Hans=y"),
    ("关WiFi(ath11k)", "# CONFIG_PACKAGE_kmod-ath11k is not set"),
    ("关USB(usb-core)", "# CONFIG_PACKAGE_kmod-usb-core is not set"),
    ("关SQM", "# CONFIG_PACKAGE_sqm-scripts is not set"),
    ("关Passwall", "# CONFIG_PACKAGE_luci-app-passwall is not set"),
    ("关OpenClash", "# CONFIG_PACKAGE_luci-app-openclash is not set"),
    ("关Argon(只Aurora)", "# CONFIG_PACKAGE_luci-theme-argon is not set"),
    ("zram(默认关闭,性能优先)", "# CONFIG_PACKAGE_zram-swap is not set"),
    ("ath11k MEM_PROFILE(关WiFi故关闭)", "# CONFIG_ATH11K_MEM_PROFILE_512M is not set"),
    ("ATH11K_NSS_MESH(关WiFi故关闭)", "# CONFIG_ATH11K_NSS_MESH_SUPPORT is not set"),
]
text = open(tmp).read()
ok = 0
for name, sym in must:
    if sym.startswith("# "):
        found = (sym[2:] in text)
    else:
        found = bool(re.search(r"^" + re.escape(sym) + r"\s*$", text, re.M))
    print(f"  [{'OK' if found else 'MISS'}] {name}: {sym}")
    ok += found
print(f"\n  覆盖度: {ok}/{len(must)}")
PY
echo ""

echo "--- 1c. 重复 =y 定义（提示） ---"
awk '/^CONFIG_[A-Za-z0-9_]+=[ym]$/ { c[$0]++ } END { for (k in c) if (c[k]>1) print "  DUP: "k }' "$TMP"
echo ""

echo "########## 2. files/ 覆盖层完整性 ##########"
for f in etc/uci-defaults/99-znm2-defaults etc/init.d/nss-qos etc/config/smartdns etc/smartdns/smartdns.conf etc/nss-qos/traffic-classify.nft; do
  [ -f "files/$f" ] && echo "  [OK] files/$f" || echo "  [MISS] files/$f"
done
echo ""

echo "########## 3. 脚本语法 (bash -n) ##########"
for f in scripts/ZN-M2-script.sh files/etc/uci-defaults/99-znm2-defaults files/etc/init.d/nss-qos check-config.sh validate.sh final-check.sh; do
  bash -n "$f" && echo "  [OK] $f"
done
echo ""

echo "########## 4. YAML 语法 ##########"
python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    yaml.safe_load(open(f)); print('  [OK]', f)
"
echo ""

echo "########## 5. ZN-M2-script.sh 引用一致性 ##########"
echo -n "  package_enabled 符号在 config 有声明(或自动依赖): "
missing=0
grep -o 'package_enabled [a-z0-9 -]*' scripts/ZN-M2-script.sh | while read -r line; do
  for pkg in $(echo "$line" | sed 's/^package_enabled //'); do
    sym="CONFIG_PACKAGE_$pkg"
    if ! grep -qE "^${sym}(=[ym])?[[:space:]]*$" configs/General.config configs/ZN-M2.config 2>/dev/null; then
      echo "$sym"
    fi
  done
done | { count=$(wc -l); echo "($count 未显式声明, 可能由依赖自动选中)"; }

echo ""
echo "########## final-check done ##########"
rm -f "$TMP"
