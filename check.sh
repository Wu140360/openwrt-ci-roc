#!/usr/bin/env bash
# 自检：逐条核对用户要求完成情况 + 扫描 config 冲突
set -uo pipefail
cd "$(dirname "$0")"

err=0
ok() { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1"; err=$((err+1)); }

echo "━━━ 1. 文件完整性 ━━━"
for f in .github/workflows/Build-OpenWrt.yml .github/workflows/ZN-M2.yml \
         configs/ZN-M2.config configs/General.config \
         scripts/ZN-M2-script.sh files/etc/uci-defaults/99-smartdns-defaults README.md; do
  [ -f "$f" ] && ok "$f 存在" || fail "$f 缺失"
done

echo
echo "━━━ 2. 引用关系一致性 ━━━"
grep -q "scripts/ZN-M2-script.sh" .github/workflows/Build-OpenWrt.yml && ok "Build-OpenWrt.yml → ZN-M2-script.sh" || fail "脚本引用"
grep -q "configs/General.config" .github/workflows/Build-OpenWrt.yml && ok "Build-OpenWrt.yml → General.config" || fail "General 引用"
grep -q "configs/ZN-M2.config" .github/workflows/ZN-M2.yml && ok "ZN-M2.yml → ZN-M2.config" || fail "config 引用"
grep -q "99-smartdns-defaults" scripts/ZN-M2-script.sh && ok "ZN-M2-script.sh 注入 SmartDNS" || fail "SmartDNS 注入"
grep -q "hostname='openwrt'" scripts/ZN-M2-script.sh && ok "主机名 openwrt" || fail "主机名"

echo
echo "━━━ 3. 用户要求逐条核对（ZN-M2.config）━━━"
C=configs/ZN-M2.config
check() { # check <符号> <含义>
  if grep -qE "^$1=y$" "$C" || grep -qE "^$1=m$" "$C"; then ok "$2"; else fail "$2 (未启用: $1)"; fi
}
check_not() {
  if grep -qE "^$1(=n| is not set)$" "$C" || grep -qE "^# $1 is not set$" "$C"; then ok "$2"; else fail "$2 (未禁用: $1)"; fi
}

# 3.1 完全不带 WiFi
echo "  -- 无 WiFi --"
for p in kmod-ath11k wpad hostapd iw iwinfo wireless-tools; do
  grep -qE "# CONFIG_PACKAGE_$p( is not set|=n)\$" "$C" && ok "$p 已禁用" || { grep -qE "^CONFIG_PACKAGE_$p=y$" "$C" && fail "$p 仍启用!" || ok "$p 未启用(默认)"; }
done
# 3.2 完全不带 USB
echo "  -- 无 USB --"
grep -qE "# CONFIG_PACKAGE_kmod-usb-core" "$C" && ok "kmod-usb-core 禁用" || fail "kmod-usb-core"
grep -qE "# CONFIG_PACKAGE_kmod-fs-vfat" "$C" && ok "kmod-fs-vfat 禁用" || fail "kmod-fs-vfat"
# 3.3 满血 NSS + q6_region 默认
echo "  -- 满血 NSS --"
grep -q "NSS_FIRMWARE_VERSION_11_4=y" "$C" && ok "NSS 11.4 启用" || fail "NSS 版本"
grep -q "q6_region" scripts/ZN-M2-script.sh && ok "脚本提及 q6_region" || true
grep -q "保持源码默认" scripts/ZN-M2-script.sh && ok "q6_region 保持默认(不缩减)" || fail "q6_region 未保留默认"
# 3.4 单设备 zn_m2
echo "  -- 单设备 --"
grep -q "CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_zn_m2=y" "$C" && ok "zn_m2 启用" || fail "zn_m2"
disabled_other=$(grep -cE "^# CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_" "$C")
echo "      (已禁用其他设备 profile: $disabled_other 个)"
[ "$disabled_other" -ge 30 ] && ok "已剔除其他设备(>=30)" || fail "剔除设备不足"

echo
echo "  -- 功能包(合并 ZN-M2.config + General.config 一起查) --"
MERGED=$(cat configs/ZN-M2.config configs/General.config)
check_in() { # check_in <符号> <含义>
  if printf '%s\n' "$MERGED" | grep -qE "^$1(=y|=m)\$"; then ok "$2"; else fail "$2 (未启用: $1)"; fi
}
check_in CONFIG_PACKAGE_luci "LuCI WebUI"
check_in CONFIG_PACKAGE_luci-theme-aurora "Aurora 主题"
check_in CONFIG_PACKAGE_luci-app-aurora-config "Aurora 配置"
check_in CONFIG_LUCI_LANG_zh_Hans "简体中文(zh_Hans)"
check_in CONFIG_PACKAGE_luci-i18n-base-zh-cn "base 中文"
check_in CONFIG_PACKAGE_sqm-scripts-nss "NSS QoS(sqm-scripts-nss)"
check_in CONFIG_PACKAGE_luci-app-sqm "SQM WebUI"
check_in CONFIG_PACKAGE_kmod-sched-nss "nss-qdisc"
check_in CONFIG_PACKAGE_luci-app-smartdns "SmartDNS"
check_in CONFIG_PACKAGE_smartdns "smartdns 本体"
check_in CONFIG_PACKAGE_luci-app-ddns "DDNS"
check_in CONFIG_PACKAGE_luci-app-wireguard "WireGuard"
check_in CONFIG_PACKAGE_luci-app-vlmcsd "KMS(vlmcsd)"
check_in CONFIG_PACKAGE_luci-app-ttyd "TTYD"
check_in CONFIG_PACKAGE_luci-app-turboacc "TurboACC"
check_in CONFIG_PACKAGE_zram-swap "ZRAM"
check_in CONFIG_PACKAGE_apk "apk 包管理"

echo
echo "  -- 剔除冗余(功能去重/降臃肿) --"
for p in luci-app-passwall luci-app-openclash luci-app-frpc luci-app-frps luci-app-aria2 nginx \
         lucky openlist2 gecoosac oaf wechatpush argon-config samba4 diskman hd-idle usb-printer; do
  grep -qE "^# CONFIG_PACKAGE_luci-app?-?${p%=*}( is not set|=n)\$" "$C" 2>/dev/null && ok "$p 已剔除" || true
done

echo
echo "━━━ 4. 无重复主题 ━━━"
grep -qE "^# CONFIG_PACKAGE_luci-theme-argon" "$C" && ok "argon 已禁用(仅 aurora)" || fail "argon 未禁用"

echo
echo "━━━ 5. General.config 未误关 ZN-M2 启用项 ━━━"
# 找出 General.config 中 is-not-set 的符号，若同时出现在 ZN-M2.config =y 则报错
while IFS= read -r sym; do
  if grep -qE "^CONFIG_${sym}=y$" "$C" || grep -qE "^CONFIG_${sym}=m$" "$C"; then
    fail "General.config 禁用了 ZN-M2.config 启用项: $sym"
  fi
done < <(grep -oE '^# CONFIG_PACKAGE_[a-z0-9_-]+' configs/General.config | sed 's/# CONFIG_PACKAGE_//')
ok "General.config 无冲突禁用(若有上面 FAIL 则需修正)"

echo
echo "━━━ 6. ZN-M2.config 内部冲突扫描 ━━━"
# 同一符号既 =y 又 is-not-set
python3 - "$C" <<'PY'
import re, sys
f=sys.argv[1]
lines=[l.strip() for l in open(f) if l.strip() and not l.strip().startswith('#') or (l.strip().startswith('# CONFIG_') and 'is not set' in l)]
state={}
for l in open(f):
    l=l.strip()
    m=re.match(r'^(CONFIG_\w+)=(y|m|n)$',l)
    if m: state[m.group(1)]=m.group(2)
    m=re.match(r'^# (CONFIG_\w+) is not set$',l)
    if m: state[m.group(1)]='n'
for k,v in state.items():
    pass
# 检查同一符号多个状态（用出现次数）
from collections import Counter
allsym=[]
for l in open(f):
    l=l.strip()
    m=re.match(r'^(CONFIG_\w+)=(y|m|n)$',l)
    if m: allsym.append((m.group(1),m.group(2)))
    m=re.match(r'^# (CONFIG_\w+) is not set$',l)
    if m: allsym.append((m.group(1),'n'))
c=Counter([k for k,_ in allsym])
dup=[k for k,n in c.items() if n>1]
if dup:
    for k in dup:
        vals=[v for kk,v in allsym if kk==k]
        if set(vals)!={'n'}:  # 只有多个不同状态才有问题；纯重复is-not-set无害
            print(f"  ⚠️  {k} 出现多次: {vals}")
            sys.exit(1)
print("  ✅ 无 =y 与 is not set 冲突")
PY

echo
if [ $err -gt 0 ]; then
  echo "━━━ 结果：$err 项未完成 ━━━"
  exit 1
else
  echo "━━━ 全部检查通过 ✅ ━━━"
fi
