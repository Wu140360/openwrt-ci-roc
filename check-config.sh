#!/usr/bin/env bash
### 配置一致性检查：冲突、重复、引用完整性
set -uo pipefail
cd "$(dirname "$0")"

echo "=== [1] 收集所有 CONFIG 符号状态（General + ZN-M2）==="
# 提取形如 CONFIG_XXX=y / =m / =n / "# CONFIG_XXX is not set"
awk '
  /^[[:space:]]*#/ { next }
  /^CONFIG_/ {
    if ($0 ~ /=[ym]$/) { sub(/=[ym]$/,"",$0); enabled[$0]=1 }
    else if ($0 ~ /=n$/) { sub(/=n$/,"",$0); disabled[$0]=1 }
  }
  /^# CONFIG_.* is not set$/ {
    line=$0; sub(/^# /,"",line); sub(/ is not set$/,"",line)
    disabled[line]=1
  }
  END {
    for (s in enabled) if (disabled[s]) printf "CONFLICT: %s (enabled AND disabled)\n", s
  }
' configs/General.config configs/ZN-M2.config

echo ""
echo "=== [2] 跨文件重复定义（同一符号多处 =y，非错误但提示）==="
awk '
  /^CONFIG_[A-Za-z0-9_]+=[ym]$/ {
    sym=$0; sub(/=[ym]$/,"",sym)
    count[sym]++
    if (count[sym]==1) first[sym]=FILENAME
    else printf "DUPLICATE: %s in %s (also %s)\n", sym, FILENAME, first[sym]
  }
' configs/General.config configs/ZN-M2.config

echo ""
echo "=== [3] ZN-M2-script.sh 引用的 package_enabled 符号是否在 config 中声明 ==="
# 提取脚本里 package_enabled 调用行的所有包名
grep -o 'package_enabled [a-z0-9 -]*' scripts/ZN-M2-script.sh | while read -r line; do
  for pkg in $(echo "$line" | sed 's/^package_enabled //'); do
    sym="CONFIG_PACKAGE_$pkg"
    if ! grep -qE "^${sym}(=[ym])?[[:space:]]*$" configs/General.config configs/ZN-M2.config 2>/dev/null; then
      echo "INFO: $sym not explicitly =y (may be auto-selected by dependencies)"
    fi
  done
done

echo ""
echo "=== [4] files/ 覆盖层文件权限（uci-defaults & init.d 必须可执行）==="
for f in files/etc/uci-defaults/99-znm2-defaults files/etc/init.d/nss-qos; do
  if [ -x "$f" ]; then echo "executable: $f OK"; else echo "FIXING: $f -> chmod +x"; chmod +x "$f"; fi
done

echo ""
echo "=== [5] 关键需求符号清单核对 ==="
declare -a must=(
  "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y"
  "CONFIG_PACKAGE_kmod-qca-nss-drv=y"
  "# CONFIG_PACKAGE_kmod-qca-nss-qdisc is not set"
  "# CONFIG_PACKAGE_qca-nss-qdisc is not set"
  "CONFIG_PACKAGE_smartdns=y"
  "CONFIG_PACKAGE_luci-app-smartdns=y"
  "CONFIG_PACKAGE_luci-theme-aurora=y"
  "CONFIG_PACKAGE_luci-app-aurora-config=y"
  "CONFIG_PACKAGE_luci-app-ttyd=y"
  "CONFIG_PACKAGE_luci-app-ddns=y"
  "CONFIG_PACKAGE_luci-proto-wireguard=y"
  "CONFIG_PACKAGE_luci-app-upnp=y"
  "CONFIG_PACKAGE_luci-app-vlmcsd=y"
  "CONFIG_PACKAGE_apk=y"
  "CONFIG_LUCI_LANG_zh_Hans=y"
)
for m in "${must[@]}"; do
  if grep -qxF "$m" configs/General.config configs/ZN-M2.config; then
    echo "  [✓] $m"
  else
    echo "  [✗] MISSING: $m"
  fi
done

echo ""
echo "=== [6] 剔除项确认（不应出现 =y）==="
declare -a banned=(
  "CONFIG_PACKAGE_luci-app-passwall=y"
  "CONFIG_PACKAGE_luci-app-openclash=y"
  "CONFIG_PACKAGE_luci-theme-argon=y"
  "CONFIG_PACKAGE_sqm-scripts=y"
)
for b in "${banned[@]}"; do
  if grep -qxF "$b" configs/General.config configs/ZN-M2.config; then
    echo "  [!] STILL ENABLED: $b"
  else
    echo "  [✓] $b absent"
  fi
done

echo ""
echo "=== check done ==="
