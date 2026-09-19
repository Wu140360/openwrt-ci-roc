#!/usr/bin/env bash
# ============================================================
#  兆能 ZN-M2 专用定制脚本（对应 configs/ZN-M2.config + General.config）
#  ------------------------------------------------------------
#  基于原 Roc-script.sh 改造，原则：
#    - 主机名固定为 openwrt
#    - q6_region 保持源码默认（85MB），绝不缩减，保留满血 NSS
#    - 只 clone / 覆盖“实际启用”的软件包，剔除全部冗余仓库
#      （passwall / openclash / frp / aria2 / nginx / lucky /
#       openlist / gecoosac / oaf / wechatpush / argon 等一律不拉取）
#    - 注入 SmartDNS 内置默认配置（解决 GitHub DNS 污染）
#    - 移除所有 WiFi / USB 相关处理逻辑
# ============================================================
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
        if (values[i] == package_name) found = 1
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
  local commit revision
  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"
  clone_with_retry "$target_dir" \
    --depth=1 --no-tags --branch "$branch" --single-branch "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# ============================================================
#  1) 修改默认 IP & 主机名（openwrt）& 编译署名
# ============================================================
echo "==> 设置默认 IP / 主机名(openwrt) / 编译署名"
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='openwrt'/g" package/base-files/files/bin/config_generate

luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
if [ -f "$luci_system_js" ]; then
  firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
  if grep -Fq "$firmware_version_anchor" "$luci_system_js"; then
    sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
              _('Firmware Version'),\n \
              E('span', {}, [\n \
                  (L.isObject(boardinfo.release)\n \
                  ? boardinfo.release.description + ' / '\n \
                  : '') + (luciversion || '') + ' / ',\n \
              E('a', {\n \
                  href: 'https://github.com/Wu140360/openwrt-ci-roc/releases',\n \
                  target: '_blank',\n \
                  rel: 'noopener noreferrer'\n \
                  }, [ 'Built by ZN-M2 $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
              ]),#" "$luci_system_js"
  fi
fi

# ============================================================
#  2) NSS q6_region 保持源码默认（85MB），不做任何缩减
#     说明：兆能 M2 已硬改 1GB RAM，且本配置完全不带 WiFi，
#     无需为 ath11k 预留内存，满血 NSS 完全够用，故保留默认。
# ============================================================
echo "==> q6_region 保持默认（满血 NSS），跳过任何 reg 修改"

# ============================================================
#  3) Git 稀疏克隆辅助函数
# ============================================================
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2
  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 --no-tags --branch "$branch" --single-branch \
    --filter=blob:none --sparse "$repourl"
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

# ============================================================
#  4) 按需覆盖 / 拉取软件包（仅启用项）
# ============================================================

# --- Go 工具链（ddns / frp 等依赖）---
if package_enabled luci-app-ddns ddns-scripts; then
  rm -rf feeds/packages/lang/golang
  git_sparse_clone master https://github.com/laipeng668/packages lang/golang
  mv package/golang feeds/packages/lang/golang
fi

# --- DDNS ---
if package_enabled luci-app-ddns ddns-scripts; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/laipeng668/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/laipeng668/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

# --- UPnP (miniupnpd) ---
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

# --- WoL ---
if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# --- Aurora 主题（唯一主题）---
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

# ============================================================
#  5) 注入 SmartDNS 内置默认配置（解决 GitHub DNS 污染）
# ============================================================
echo "==> 注入 SmartDNS 默认配置"
SRC_UCI="$WORKSPACE/files/etc/uci-defaults/99-smartdns-defaults"
DST_DIR="package/base-files/files/etc/uci-defaults"
if [ -f "$SRC_UCI" ]; then
  mkdir -p "$DST_DIR"
  cp "$SRC_UCI" "$DST_DIR/99-smartdns-defaults"
  chmod +x "$DST_DIR/99-smartdns-defaults"
fi

# ============================================================
#  6) 清理 PassWall / OpenClash 残留（本配置不使用，保险起见）
# ============================================================
echo "==> 清理科学上网残留（本配置不使用）"
rm -rf package/luci-app-passwall package/luci-app-passwall2 package/luci-app-openclash \
       package/passwall-packages 2>/dev/null || true

# ============================================================
#  7) 更新 / 安装 feeds
# ============================================================
./scripts/feeds update -i -a
./scripts/feeds install -a

echo "==> ZN-M2 定制脚本执行完成"
