#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  # Keep direct invocations compatible with an existing OpenWrt .config.
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 修改默认IP & 固件名称 & 编译署名和时间
sed -i 's/192.168.1.1/192.168.3.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' / ',\n \
            E('a', {\n \
                href: 'https://github.com/laipeng668/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by Roc $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# ===== 本分支定制：兆能 ZN-M2 无 WiFi / 满血 NSS =====
# 仅在设备配置显式关闭 kmod-ath11k 时生效，避免影响同仓库其它机型的 workflow
if grep -Fxq 'CONFIG_PACKAGE_kmod-ath11k=n' "${CONFIG_FILES[@]}"; then
  # 1) q6_region 预留 16MB（ipq6018-512m.dtsi 默认 55MB，带 WiFi 至少需 54MB；无 WiFi 时把内存归还系统）
  q6_dtsi="target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi"
  [ -f "$q6_dtsi" ] || { echo "Error: $q6_dtsi not found" >&2; exit 1; }
  sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' "$q6_dtsi"
  grep -q '0x4ab00000 0x0 0x01000000' "$q6_dtsi" || { echo "Error: q6_region 16MB patch failed" >&2; exit 1; }

  # 2) 彻底禁用 ZN-M2 的 WiFi 硬件节点（原 DTS 显式 status = "okay"）
  zn_m2_dts="target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6000-m2.dts"
  [ -f "$zn_m2_dts" ] || { echo "Error: $zn_m2_dts not found" >&2; exit 1; }
  python3 - "$zn_m2_dts" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
start = s.find("&wifi {")
if start >= 0:
    end = s.find("};", start)
    if end < 0:
        sys.exit("Error: unterminated &wifi node")
    s = s[:start] + '&wifi {\n\tstatus = "disabled";\n};' + s[end + 2:]
    p.write_text(s.rstrip("\n") + "\n")
PY
  grep -q 'status = "disabled"' "$zn_m2_dts" || { echo "Error: ZN-M2 wifi node disable failed" >&2; exit 1; }

  # 3) 移除 zn_m2 设备级默认 WiFi 包（沿用源码内 jdcloud_re-cs-07 的无 WiFi 写法）
  ipq60xx_mk="target/linux/qualcommax/image/ipq60xx.mk"
  [ -f "$ipq60xx_mk" ] || { echo "Error: $ipq60xx_mk not found" >&2; exit 1; }
  python3 - "$ipq60xx_mk" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "\tDEVICE_PACKAGES := ipq-wifi-zn_m2\n"
new = ("\tDEVICE_PACKAGES := -ipq-wifi-zn_m2 -ath11k-firmware-ipq6018 "
       "-ath11k-firmware-qcn9074 -kmod-ath11k -kmod-ath11k-ahb "
       "-kmod-ath11k-pci -hostapd-common -wpad-openssl\n")
if old not in s:
    sys.exit("Error: zn_m2 DEVICE_PACKAGES anchor not found")
p.write_text(s.replace(old, new, 1))
PY
  grep -q 'DEVICE_PACKAGES := -ipq-wifi-zn_m2' "$ipq60xx_mk" || { echo "Error: zn_m2 wifi packages exclusion failed" >&2; exit 1; }
fi

# 调节IPQ60XX的1.5GHz频率电压(从0.9375V提高到0.95V，过低可能导致不稳定，过高可能增加功耗和发热，具体数值需要根据实际情况调整)
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# Aria2 & nginx & Go & DDNS & frp & UPnP & Wol
rm -rf feeds/packages/lang/golang
git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv package/golang feeds/packages/lang/golang

if package_enabled luci-app-aria2 aria2; then
  rm -rf feeds/packages/net/aria2
  git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
  mv package/aria2 feeds/packages/net/aria2
fi
if package_enabled ariang; then
  rm -rf feeds/packages/net/ariang
  git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
  mv package/ariang feeds/packages/net/ariang
fi

if package_enabled nginx nginx-full nginx-ssl luci-app-nginx; then
  rm -rf feeds/packages/net/nginx
  git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
  mv package/nginx feeds/packages/net/nginx
fi

if package_enabled luci-app-ddns ddns-scripts ddns-scripts-cloudflare; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/laipeng668/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

if package_enabled frp frpc frps luci-app-frpc luci-app-frps; then
  rm -rf \
    feeds/packages/net/frp
  git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
  mv package/frp feeds/packages/net/frp
fi

frp_luci_paths=()
if package_enabled luci-app-frpc; then
  rm -rf feeds/luci/applications/luci-app-frpc
  frp_luci_paths+=(applications/luci-app-frpc)
fi
if package_enabled luci-app-frps; then
  rm -rf feeds/luci/applications/luci-app-frps
  frp_luci_paths+=(applications/luci-app-frps)
fi
if [ "${#frp_luci_paths[@]}" -gt 0 ]; then
  git_sparse_clone frp https://github.com/laipeng668/luci "${frp_luci_paths[@]}"
  for frp_luci_path in "${frp_luci_paths[@]}"; do
    mv "package/$(basename "$frp_luci_path")" "feeds/luci/$frp_luci_path"
    sed -i '/^LUCI_EXTRA_DEPENDS:=/d' "feeds/luci/$frp_luci_path/Makefile"
  done
fi

if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# Themes and standalone applications. A config application pulls in its theme as a dependency.
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

if package_enabled luci-app-openlist2 openlist2; then
  clone_repository https://github.com/laipeng668/luci-app-openlist2 main package/openlist2
fi

if package_enabled luci-app-lucky lucky; then
  clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky

  # ===== Lucky「小满」版：从官方文件服务动态取最新版，不写死版本号 =====
  # 版本可由 workflow 输入 lucky_version 指定；默认 auto 自动发现。
  # 官方目录/文件命名：v<VER>/<VER>_xiaoman/lucky_<VER>_Linux_arm64_xiaoman.tar.gz
  LUCKY_RELEASE_BASE="${LUCKY_RELEASE_BASE:-https://release.66666.host}"
  LUCKY_RELEASE_MIRROR="${LUCKY_RELEASE_MIRROR:-https://lucky666.cn/release}"
  LUCKY_REQUESTED_VERSION="${LUCKY_VERSION:-auto}"

  lucky_url_for() {
    local base="$1" ver="$2"
    printf '%s/v%s/%s_xiaoman/lucky_%s_Linux_arm64_xiaoman.tar.gz' \
      "$base" "$ver" "$ver" "$ver"
  }

  collect_lucky_versions() {
    local base page
    {
      for base in "$LUCKY_RELEASE_BASE" "$LUCKY_RELEASE_MIRROR"; do
        for page in "$base/install.sh" "$base/"; do
          curl -fsSL --max-time 30 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" "$page" 2>/dev/null || true
        done
      done
    } | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | uniq || true
  }

  if [ "$LUCKY_REQUESTED_VERSION" != "auto" ]; then
    lucky_candidates="${LUCKY_REQUESTED_VERSION#v}"
  else
    lucky_candidates="$(collect_lucky_versions | head -n 12 || true)"
  fi

  mkdir -p dl
  LUCKY_VER=""
  LUCKY_TARBALL=""
  LUCKY_SELECTED_BASE=""
  for candidate in $lucky_candidates; do
    [ -n "$candidate" ] || continue
    tarball="lucky_${candidate}_Linux_arm64_xiaoman.tar.gz"
    for base in "$LUCKY_RELEASE_BASE" "$LUCKY_RELEASE_MIRROR"; do
      rm -f "dl/$tarball" dl/.lucky-list
      if curl -fsSL --retry 2 --max-time 300 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
           "$(lucky_url_for "$base" "$candidate")" -o "dl/$tarball" \
           && [ -s "dl/$tarball" ]; then
        if tar -tzf "dl/$tarball" > dl/.lucky-list 2>/dev/null \
             && grep -Eq '(^|/)lucky$' dl/.lucky-list; then
          LUCKY_VER="$candidate"
          LUCKY_TARBALL="$tarball"
          LUCKY_SELECTED_BASE="$base"
          break 2
        fi
      fi
    done
  done
  rm -f dl/.lucky-list

  if [ -z "$LUCKY_VER" ]; then
    echo "Error: 无法从 ${LUCKY_RELEASE_BASE} 获取 Lucky 小满 (Linux arm64)；请在工作流中显式指定 lucky_version。" >&2
    exit 1
  fi
  echo "Lucky 小满版: ${LUCKY_VER} <- ${LUCKY_SELECTED_BASE}/${LUCKY_TARBALL}"

  # 改写 lucky 核心包的下载源与版本；PKG_HASH 原本即为 skip，tar 内二进制名仍为 lucky
  lucky_makefile="package/luci-app-lucky/lucky/Makefile"
  [ -f "$lucky_makefile" ] || { echo "Error: $lucky_makefile not found" >&2; exit 1; }
  sed -i \
    -e "s|^PKG_VERSION:=.*|PKG_VERSION:=${LUCKY_VER}|" \
    -e 's|^PKG_SOURCE:=.*|PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_xiaoman.tar.gz|' \
    -e "s|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=${LUCKY_SELECTED_BASE}/v\$(PKG_VERSION)/\$(PKG_VERSION)_xiaoman|" \
    "$lucky_makefile"
  grep -q "^PKG_VERSION:=${LUCKY_VER}$" "$lucky_makefile" \
    || { echo "Error: lucky Makefile 版本改写失败" >&2; exit 1; }
  printf 'Lucky-XiaoMan\t%s\t%s\n' "$LUCKY_VER" \
    "$(lucky_url_for "$LUCKY_SELECTED_BASE" "$LUCKY_VER")" >> "$THIRD_PARTY_SOURCES_FILE"
fi

if package_enabled luci-app-wechatpush; then
  rm -rf feeds/luci/applications/luci-app-wechatpush
  clone_repository https://github.com/tty228/luci-app-wechatpush master package/luci-app-wechatpush
fi

if package_enabled luci-app-oaf open-app-filter; then
  rm -rf feeds/luci/applications/luci-app-appfilter feeds/packages/net/open-app-filter
  clone_repository https://github.com/destan19/OpenAppFilter.git master package/OpenAppFilter
fi

if package_enabled luci-app-gecoosac gecoosac; then
  clone_repository https://github.com/laipeng668/luci-app-gecoosac main package/luci-app-gecoosac
fi

if package_enabled luci-app-athena-led luci-i18n-athena-led-zh-cn; then
  clone_repository https://github.com/NONGFAH/luci-app-athena-led main package/luci-app-athena-led
  chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led
fi

### PassWall & OpenClash ###

if package_enabled luci-app-passwall luci-app-passwall2; then
  # 移除 OpenWrt Feeds 自带的核心库
  rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall-packages main package/passwall-packages
fi

if package_enabled luci-app-passwall; then
  rm -rf feeds/luci/applications/luci-app-passwall
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall main package/luci-app-passwall
fi

if package_enabled luci-app-passwall2; then
  rm -rf feeds/luci/applications/luci-app-passwall2
  clone_repository https://github.com/Openwrt-Passwall/openwrt-passwall2 main package/luci-app-passwall2
fi

if package_enabled luci-app-openclash; then
  rm -rf feeds/luci/applications/luci-app-openclash
  clone_repository https://github.com/vernesong/OpenClash master package/luci-app-openclash
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a

# ===== 修复 OpenClash → ruby → rust/host 编译失败 =====
# immortalwrt/packages 的 ruby 在 aarch64 默认 RUBY_ENABLE_YJIT=y，
# PKG_BUILD_DEPENDS 含 RUBY_ENABLE_YJIT:rust/host；rust 1.96.0 host 编译
# 写死 llvm.download-ci-llvm=true，需从 ci-artifacts.rust-lang.org 下载
# rust-dev-1.96.0-*.tar.xz（该 CI 产物已 404），导致 world 构建必然失败。
# OpenClash 仅用 ruby 解释器 + ruby-yaml 解析 YAML，YJIT 非必需：
# 关闭默认 YJIT 并摘掉 rust/host 构建依赖，ruby 走 --disable-yjit 正常编译。
ruby_makefile="feeds/packages/lang/ruby/Makefile"
if [ ! -f "$ruby_makefile" ]; then
  echo "Error: $ruby_makefile not found; cannot disable ruby YJIT/rust host dependency" >&2
  exit 1
fi
sed -i \
  -e 's#[[:space:]]*RUBY_ENABLE_YJIT:rust/host##' \
  -e 's#^[[:space:]]*default y if x86_64||aarch64$#    default n#' \
  "$ruby_makefile"
if grep -q 'RUBY_ENABLE_YJIT:rust/host' "$ruby_makefile" \
   || grep -q 'default y if x86_64' "$ruby_makefile"; then
  echo "Error: ruby YJIT / rust host 依赖补丁未生效" >&2
  exit 1
fi
grep -q '^[[:space:]]*default n[[:space:]]*$' "$ruby_makefile" \
  || { echo "Error: ruby YJIT 默认值未改为 n" >&2; exit 1; }
echo "ruby: YJIT disabled, rust/host build dependency removed"
