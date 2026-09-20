#!/usr/bin/env bash
### ============================================================
###  兆能 M2 专用 DIY 脚本（对标 Roc-script.sh，仅保留本需求相关部分）
###  用法：ZN-M2-script.sh <device_config> [general_config]
###  被 Build-OpenWrt.yml 的 "Load Custom Configuration" 步骤调用
###
###  设计原则：
###  1. 不引入任何科学上网 / 代理 / Argon 等被剔除的包；
###  2. 第三方包按需克隆，且【先检查 feed 是否已存在】——避免覆盖 LibWrt 自带包造成冲突；
###  3. 克隆 / 补丁失败【仅警告、不致命】，保证核心固件一定能编译出来；
###  4. 绝不修改 q6_region / reserved-memory / DTS（保持满血 NSS 默认）。
### ============================================================
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OWRT="${OPENWRT_PATH:-$PWD}"
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

log()  { printf '\n==> [ZN-M2] %s\n' "$*" >&2; }
warn() { printf '==> [ZN-M2][WARN] %s\n' "$*" >&2; }

### ---------- 工具函数 ----------
resolve_config_file() {
  local config_file="$1"
  if [ -f "$config_file" ]; then printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then printf '%s\n' "$WORKSPACE/$config_file"
  else echo "Error: configuration file was not found: $config_file" >&2; return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2; exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

# 读取 config 中某 symbol 是否被启用（=y 或 =m）
config_symbol_enabled() {
  local symbol="$1"
  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name
  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name"; then return 0; fi
  done
  return 1
}

# 克隆失败仅警告，不致命（保证核心固件可编译）
clone_with_retry() {
  local target_dir="$1" attempt
  shift
  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir" 2>/dev/null; then return 0; fi
    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      warn "git clone failed (attempt $attempt/$GIT_CLONE_RETRY_COUNT): ${*: -1}; retrying"
      sleep $((attempt * 2))
    fi
  done
  warn "git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1} (SKIPPED)"
  return 1
}

record_git_revision() {
  local repo_url="$1" branch="$2" checkout_dir="$3" commit revision
  [ -d "$checkout_dir" ] || return 0
  commit="$(git -C "$checkout_dir" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$commit" ] || return 0
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1" branch="$2" target_dir="$3"
  if clone_with_retry "$target_dir" --depth=1 --no-tags --branch "$branch" --single-branch "$repo_url"; then
    record_git_revision "$repo_url" "$branch" "$target_dir"
    return 0
  fi
  rm -rf "$target_dir"
  return 1
}

git_sparse_clone() {
  local branch="$1" repourl="$2" repodir sparse_path
  shift 2
  repodir="$(basename "${repourl%.git}")"
  if clone_with_retry "$repodir" --depth=1 --no-tags --branch "$branch" --single-branch \
        --filter=blob:none --sparse "$repourl"; then
    ( cd "$repodir" && git sparse-checkout set "$@" ) || true
    record_git_revision "$repourl" "$branch" "$repodir"
    for sparse_path in "$@"; do
      rm -rf "package/$(basename "$sparse_path")"
      mv "$repodir/$sparse_path" package/
    done
    rm -rf "$repodir"
    return 0
  fi
  rm -rf "$repodir"
  return 1
}

# 仅在目标路径【不存在】时才克隆（避免覆盖 LibWrt 自带包造成冲突）
ensure_clone_repo() {
  local dest="$1" repo_url="$2" branch="$3"
  if [ -e "$dest" ]; then log "already present, skip clone: $dest"; return 0; fi
  clone_repository "$repo_url" "$branch" "$dest" || true
}

ensure_sparse() {
  local dest_sub="$1" repo_url="$2" branch="$3"; shift 3
  if [ -e "$dest_sub" ]; then log "already present, skip: $dest_sub"; return 0; fi
  git_sparse_clone "$branch" "$repo_url" "$@" || true
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

### ============================================================
###  1. 默认设置：设备名 openwrt、默认 IP 192.168.2.1、固件署名
### ============================================================
log "set hostname = openwrt, ip = 192.168.2.1"
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='openwrt'/g" package/base-files/files/bin/config_generate

luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
if [ -f "$luci_system_js" ] && grep -Fq "$firmware_version_anchor" "$luci_system_js" 2>/dev/null; then
  grep -Fq "Built by ZN-M2" "$luci_system_js" || \
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
              ]),#" "$luci_system_js" 2>/dev/null || warn "firmware signature sed skipped"
else
  warn "$luci_system_js not found or anchor missing — skip firmware signature (non-fatal)"
fi

### ============================================================
###  2. 拷贝 files/ 覆盖层（SmartDNS / NSS QoS / uci-defaults / ttyd 工具）
###     OpenWrt 构建系统会自动把 $TOPDIR/files/ 打包进固件
### ============================================================
if [ -d "$WORKSPACE/files" ]; then
  log "overlay files/ -> $OWRT/files/"
  mkdir -p "$OWRT/files"
  cp -a "$WORKSPACE/files/." "$OWRT/files/."
  chmod +x "$OWRT/files/etc/uci-defaults/99-znm2-defaults" 2>/dev/null || true
  chmod +x "$OWRT/files/etc/init.d/nss-qos" 2>/dev/null || true
else
  warn "no files/ overlay in workspace — skip"
fi

### ============================================================
###  3. 按需克隆额外软件包（仅在 feed 未自带、且 config 启用时才拉取）
###     Aurora / DDNS / UPnP / SmartDNS / vlmcsd —— 均先检查已存在性，失败仅警告
### ============================================================

### --- Aurora 主题 + 配置应用（唯一主题，含 config app；剔除 Argon）---
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  ensure_clone_repo feeds/luci/themes/luci-theme-aurora \
    https://github.com/eamonxg/luci-theme-aurora master
fi
if package_enabled luci-app-aurora-config; then
  ensure_clone_repo feeds/luci/applications/luci-app-aurora-config \
    https://github.com/eamonxg/luci-app-aurora-config master
fi

### --- DDNS（cloudflare 适配；仅当 feed 未自带时补充）---
if package_enabled luci-app-ddns; then
  ensure_sparse feeds/luci/applications/luci-app-ddns \
    https://github.com/laipeng668/luci master applications/luci-app-ddns
fi

### --- UPnP（仅当 feed 未自带时补充）---
if package_enabled luci-app-upnp miniupnpd; then
  ensure_sparse feeds/packages/net/miniupnpd \
    https://github.com/immortalwrt/packages master net/miniupnpd
  ensure_sparse feeds/luci/applications/luci-app-upnp \
    https://github.com/immortalwrt/luci master applications/luci-app-upnp
fi

### --- SmartDNS（若 feed 未含，则从源仓库补充）---
if package_enabled luci-app-smartdns smartdns; then
  if [ ! -d feeds/packages/net/smartdns ] && [ ! -d package/smartdns ]; then
    clone_repository https://github.com/pymumu/smartdns master package/smartdns || true
  fi
  if package_enabled luci-app-smartdns && [ ! -d feeds/luci/applications/luci-app-smartdns ]; then
    git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-smartdns || true
  fi
fi

### --- WireGuard：25.12 内核内置 kmod-wireguard，通常无需额外克隆 ---
if package_enabled luci-proto-wireguard wireguard-tools; then
  log "WireGuard: use in-tree kmod-wireguard + luci-proto-wireguard (no extra clone)"
fi

### --- KMS (vlmcsd)：守护进程通常随 base 提供；LuCI/i18n 若 feed 无则跳过，已在 config 注释说明 ---
if package_enabled luci-app-vlmcsd vlmcsd; then
  log "KMS: vlmcsd enabled; if luci-app-vlmcsd / i18n missing in feeds, comment the three lines in General.config"
fi

### --- ttyd（Web 终端，含常用诊断工具；feed 存在性由 make 决定，此处仅提示）---
if package_enabled luci-app-ttyd ttyd; then
  log "ttyd: ensure LuCI app present (feed or files/ overlay)"
fi

### ============================================================
###  4. 严格剔除（本需求明确不需要，避免误编译 / 依赖冲突）
###     General.config 已用 "# ... is not set" 显式关闭，此处做运行时兜底断言
### ============================================================
log "ensure no proxy / redundant QoS / Argon packages selected"
for sym in \
  CONFIG_PACKAGE_luci-app-passwall=y \
  CONFIG_PACKAGE_luci-app-passwall2=y \
  CONFIG_PACKAGE_luci-app-openclash=y \
  CONFIG_PACKAGE_luci-app-argon-config=y \
  CONFIG_PACKAGE_luci-theme-argon=y \
  CONFIG_PACKAGE_sqm-scripts=y \
  CONFIG_PACKAGE_sqm-scripts-nss=y \
  CONFIG_PACKAGE_qosify=y \
  CONFIG_PACKAGE_nft-qos=y \
  CONFIG_PACKAGE_luci-app-qos=y \
  ; do
  if grep -qxF "$sym" "$OWRT/.config" 2>/dev/null; then
    warn "FORBIDDEN symbol selected: $sym —— removing"
    sed -i "/^${sym}\$/d" "$OWRT/.config"
    printf '# %s\n' "$sym" >> "$OWRT/.config"
  fi
done

### ============================================================
###  5. 断言：WiFi / USB / 块存储 绝不能被选中（安全网）
### ============================================================
if [ -f "$OWRT/.config" ]; then
  bad="$(grep -E '^CONFIG_PACKAGE_(kmod-ath11k|kmod-ath10k|ath11k-firmware|wpad|hostapd|kmod-usb|usbutils|block-mount|kmod-scsi|kmod-fs-ext4|kmod-fs-vfat|hdparm|smartmontools|fstrim|fdisk|cfdisk|sgdisk)=y$' "$OWRT/.config" || true)"
  if [ -n "$bad" ]; then
    warn "The following forbidden packages are selected (auto-disabling):\n$bad"
    printf '%s\n' "$bad" | while IFS= read -r s; do
      sed -i "/^${s}\$/d" "$OWRT/.config"
      printf '# %s\n' "$s" >> "$OWRT/.config"
    done
  fi
fi

### ============================================================
###  6. 更新 feeds（应用克隆的包）
### ============================================================
./scripts/feeds update -i -a
./scripts/feeds install -a

log "customization done."
