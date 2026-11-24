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

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认85MB，ipq6018-512m.dtsi默认55MB；
# 带WiFi必须至少54MB，本固件完全无WiFi，故改为16MB=0x01000000，把内存还给系统）
q6_dtsi="target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi"
[ -f "$q6_dtsi" ] || { echo "Error: $q6_dtsi not found" >&2; exit 1; }
sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' "$q6_dtsi"
grep -Fq '0x0 0x01000000' "$q6_dtsi" || { echo "Error: q6_region 16MB patch failed" >&2; exit 1; }
# 兆能 M2 的 ipq6000-m2.dts -> ipq6000-cmiot.dtsi -> ipq6018-512m.dtsi，上面改的正是它引用的文件。

### 完全剔除 WiFi：从源码层面移除默认包与 M2 的 board 数据依赖 ###
# .config 里已用 =n 覆盖，这里再从 DEFAULT_PACKAGES / DEVICE_PACKAGES 摘干净，三重保险。
python3 - "$PWD/target/linux/qualcommax/Makefile" "$PWD/target/linux/qualcommax/image/ipq60xx.mk" <<'PYEOF'
import re, sys
qax_mk, img_mk = sys.argv[1], sys.argv[2]
s = open(qax_mk, encoding='utf-8').read()
drop = {'wpad-openssl', 'kmod-ath11k', 'kmod-ath11k-ahb', 'kmod-ath11k-pci',
        'kmod-qca-nss-drv-wifi-meshmgr'}
start = s.index('DEFAULT_PACKAGES +=')
end = s.index('\n\n', start)
pkgs = [t for t in s[start:end].replace('\\', ' ').split()[2:] if t not in drop]
lines = []
for i in range(0, len(pkgs), 8):
    lines.append('\t' + ' '.join(pkgs[i:i+8]) + (' \\' if i + 8 < len(pkgs) else ''))
new_block = 'DEFAULT_PACKAGES += \\\n' + '\n'.join(lines)
s = s[:start] + new_block + s[end:]
open(qax_mk, 'w', encoding='utf-8').write(s)

t = open(img_mk, encoding='utf-8').read()
block = re.search(r'(define Device/zn_m2\n)(.*?)(\nendef)', t, re.S)
if not block:
    sys.exit('Error: Device/zn_m2 block not found in ipq60xx.mk')
body = '\n'.join(ln for ln in block.group(2).split('\n') if 'ipq-wifi-zn_m2' not in ln)
t = t[:block.start(2)] + body + t[block.end(2):]
open(img_mk, 'w', encoding='utf-8').write(t)
PYEOF
if grep -q 'kmod-qca-nss-drv-wifi-meshmgr' target/linux/qualcommax/Makefile; then
  echo "Error: WiFi NSS module still in DEFAULT_PACKAGES" >&2
  exit 1
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

# Aria2 & nginx & DDNS & frp & UPnP & Wol
# 本分支不编译任何 Go 软件包（frp / openlist2 / passwall / aria2 均已关闭），
# 因此不再替换 feeds 自带的 golang，避免计划外的源码变更与额外下载。

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
fi

### Lucky「小满」：动态获取最新版，且只集成一个二进制、一个 LuCI 页面 ###
# 仓库自带 lucky/Makefile 拉的是标准/万吉版，这里改为发布站的 xiaoman 构建。
# 版本号完全动态解析（不写死 3.8.1），便于以后直接重跑 workflow 编新固件。
if package_enabled luci-app-lucky lucky; then
  lucky_mk="package/luci-app-lucky/lucky/Makefile"
  [ -f "$lucky_mk" ] || { echo "Error: $lucky_mk not found" >&2; exit 1; }

  browser_ua='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  fetch_index() {
    curl -fsSL --max-time 40 --retry 2 \
      -A "$browser_ua" \
      -H 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8' \
      -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8' \
      -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-Mode: navigate' \
      -H 'Upgrade-Insecure-Requests: 1' \
      "$1" 2>/dev/null || true
  }

  LUCKY_VER="${LUCKY_XIAOMAN_VERSION:-}"
  if [ -n "$LUCKY_VER" ]; then
    echo "Lucky xiaoman version pinned by env: $LUCKY_VER"
  else
    # 主：官方发布站根目录；备：官方备用域名；再备：Docker Hub 的 _xiaoman 标签
    for base in "https://release.66666.host/" "https://lucky666.cn/release/"; do
      cand="$(printf '%s\n' "$(fetch_index "$base")" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sed 's/^v//' | sort -Vu | tail -n 1 || true)"
      if [ -n "$cand" ]; then
        LUCKY_VER="$cand"
        echo "Lucky latest version from $base : $LUCKY_VER"
        break
      fi
    done
    if [ -z "$LUCKY_VER" ]; then
      dh="$(curl -fsSL --max-time 40 --retry 2 'https://hub.docker.com/v2/repositories/gdy666/lucky/tags?page_size=100&name=xiaoman' 2>/dev/null || true)"
      cand="$(printf '%s\n' "$dh" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+_xiaoman' | sed -E 's/^v//; s/_xiaoman$//' | sort -Vu | tail -n 1 || true)"
      if [ -n "$cand" ]; then
        LUCKY_VER="$cand"
        echo "Lucky latest version from Docker Hub tags: $LUCKY_VER"
      fi
    fi
  fi
  if [ -z "$LUCKY_VER" ]; then
    echo "Error: cannot resolve latest Lucky xiaoman version from release.66666.host / lucky666.cn / Docker Hub." >&2
    echo "Hint: set LUCKY_XIAOMAN_VERSION in workflow env to an explicit version and re-run." >&2
    exit 1
  fi
  case "$LUCKY_VER" in *[!0-9.]* ) echo "Error: invalid Lucky version '$LUCKY_VER'" >&2; exit 1 ;; esac

  # 改写包定义：PKG_VERSION 动态、源码文件名带 _xiaoman、源指向发布站对应版本目录
  sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=${LUCKY_VER}/" "$lucky_mk"
  sed -i 's|^PKG_SOURCE:=.*|PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_xiaoman.tar.gz|' "$lucky_mk"
  sed -i 's|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://release.66666.host/v$(PKG_VERSION)/$(PKG_VERSION)_xiaoman|' "$lucky_mk"
  grep -Fq '_xiaoman.tar.gz' "$lucky_mk" || { echo "Error: failed to switch lucky to xiaoman build" >&2; exit 1; }
  grep -Fq 'PKG_HASH:=skip' "$lucky_mk" || { echo "Error: lucky PKG_HASH changed, review download flow" >&2; exit 1; }

  # 预下载到 dl/：make download 阶段直接复用（PKG_HASH:=skip），避免二次被 WAF 拦截。
  # 若解析/下载失败则立即终止，绝不回退成标准版或猜测版本。
  dl_dir="${OPENWRT_PATH:-$PWD}/dl"
  mkdir -p "$dl_dir"
  asset="lucky_${LUCKY_VER}_Linux_arm64_xiaoman.tar.gz"
  asset_path="$dl_dir/$asset"
  if [ ! -s "$asset_path" ]; then
    ok=0
    for base in "https://release.66666.host/v${LUCKY_VER}/${LUCKY_VER}_xiaoman" \
                "https://lucky666.cn/release/v${LUCKY_VER}/${LUCKY_VER}_xiaoman"; do
      if curl -fL --max-time 180 --retry 2 -A "$browser_ua" \
           -H 'Accept: */*' -H 'Accept-Language: zh-CN,zh;q=0.9' \
           -H "Referer: ${base}/" \
           -o "$asset_path" "${base}/${asset}"; then
        if gzip -t "$asset_path" 2>/dev/null; then ok=1; break; fi
      fi
      rm -f "$asset_path"
    done
    [ "$ok" = 1 ] || { echo "Error: failed to download ${asset} (Lucky xiaoman ${LUCKY_VER})" >&2; exit 1; }
  fi
  gzip -t "$asset_path" || { echo "Error: ${asset} is not a valid gzip archive" >&2; exit 1; }
  tar -tzf "$asset_path" | grep -q 'lucky' || { echo "Error: ${asset} does not contain lucky binary" >&2; exit 1; }
  printf '# Lucky-xiaoman\t%s\t%s\n' "$LUCKY_VER" "$asset" >> "$THIRD_PARTY_SOURCES_FILE"
  echo "Lucky xiaoman ${LUCKY_VER} (arm64) ready: $asset_path"
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
  # 官方仓库 master 最新提交；用稀疏克隆只取 luci-app-openclash 包目录，
  # 避免把整个仓库塞进 package/ 造成包路径多一层或带入计划外文件。
  rm -rf feeds/luci/applications/luci-app-openclash package/luci-app-openclash
  git_sparse_clone master https://github.com/vernesong/OpenClash luci-app-openclash
  [ -f package/luci-app-openclash/Makefile ] || { echo "Error: OpenClash package Makefile missing" >&2; exit 1; }
fi

# 清理 PassWall 的 chnlist 规则文件
# echo "baidu.com"  > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

./scripts/feeds update -i -a
./scripts/feeds install -a
