#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEVICE_CONFIG_FILE="${1:-${CONFIG_FILE:-}}"
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-configs/General.config}}"
GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

# 兆能 M2 专用：lucky 万吉版 3.5.0（aarch64）离线包
LUCKY_WANJI_TARBALL_NAME="lucky_3.5.0_Linux_arm64_wanji.tar.gz"
LUCKY_WANJI_SHA256="f2715cf9e845b3220c46232bd25cf52af2603fdf7c0bebbae350e9cae23d81f6"

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
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
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

# 调整NSS驱动q6_region内存区域预留大小（ipq6018.dtsi默认预留85MB，ipq6018-512m.dtsi默认预留55MB，带WiFi必须至少预留54MB，以下分别是改成预留16MB、32MB、64MB和96MB）
# 兆能 M2 为无 WiFi 的有线加速固件，保持源码默认预留，不启用以下任何一条。
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

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

# 主题：aurora（默认主题，另含配置界面 luci-app-aurora-config）
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

# lucky：替换为万吉（wanji）3.5.0 aarch64 官方二进制
#   官方 Makefile 通过 PKG_SOURCE_URL 下载 lucky_<ver>_Linux_<arch>.tar.gz 并直接解包安装，
#   因此这里把 PKG_SOURCE 指向同一发布页的 _wanji 资源，把 PKG_HASH 固定为离线包的 sha256，
#   并把离线包预置到 dl/，使 make download 直接校验复用本地文件，避免官方版二进制覆盖万吉版。
if package_enabled luci-app-lucky lucky; then
  clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky

  lucky_makefile="package/luci-app-lucky/lucky/Makefile"
  lucky_tarball="$WORKSPACE/packages/lucky-wanji/$LUCKY_WANJI_TARBALL_NAME"

  [ -f "$lucky_makefile" ] || { echo "Error: lucky Makefile was not found: $lucky_makefile" >&2; exit 1; }
  [ -f "$lucky_tarball" ] || { echo "Error: lucky wanji tarball was not found: $lucky_tarball" >&2; exit 1; }

  # 校验离线包与官方 v3.5.0 wanji aarch64 资源完全一致（sha256 固定）
  printf '%s  %s\n' "$LUCKY_WANJI_SHA256" "$lucky_tarball" | sha256sum -c - > /dev/null || {
    echo "Error: lucky wanji tarball checksum mismatch: $lucky_tarball" >&2
    exit 1
  }
  # tar 根目录必须直接包含 lucky 可执行文件（Makefile 从 $(PKG_BUILD_DIR)/lucky 安装）
  lucky_entries="$(tar -tzf "$lucky_tarball")"
  grep -qx 'lucky' <<< "$lucky_entries" || {
    echo "Error: lucky binary was not found at the archive root: $lucky_tarball" >&2
    exit 1
  }

  grep -Fq 'PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH).tar.gz' "$lucky_makefile" || {
    echo "Error: unexpected lucky PKG_SOURCE in $lucky_makefile" >&2
    exit 1
  }
  sed -i 's|^PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)\.tar\.gz$|PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_wanji.tar.gz|' "$lucky_makefile"
  grep -Fq 'PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_wanji.tar.gz' "$lucky_makefile" || {
    echo "Error: failed to switch lucky to the wanji build" >&2
    exit 1
  }
  # 用真实 sha256 取代 skip：dl/ 里的离线包命中后 make download 直接跳过，且万一走网络下载
  # 也会强制校验为万吉版（同发布页同一资源）
  sed -i "s|^PKG_HASH:=.*\$|PKG_HASH:=$LUCKY_WANJI_SHA256|" "$lucky_makefile"
  grep -Fq "PKG_HASH:=$LUCKY_WANJI_SHA256" "$lucky_makefile" || {
    echo "Error: failed to pin lucky PKG_HASH to the wanji build" >&2
    exit 1
  }

  mkdir -p dl
  install -m 0644 "$lucky_tarball" "dl/$LUCKY_WANJI_TARBALL_NAME"
  echo "lucky: wanji 3.5.0 (aarch64) 已就绪，sha256=$LUCKY_WANJI_SHA256"
fi

# EasyTier：官方包仓库含 easytier / easytier-noweb / luci-app-easytier
#   easytier-noweb 的 Makefile 在 Build/Prepare 阶段下载官方预编译 zip（不编译 Rust），
#   这里只取 noweb 变体与 LuCI 应用以控制体积。
if package_enabled luci-app-easytier easytier easytier-noweb; then
  rm -rf package/easytier package/easytier-noweb package/luci-app-easytier
  git_sparse_clone main https://github.com/EasyTier/luci-app-easytier easytier-noweb luci-app-easytier
fi

# qos-switch：三态 QoS 切换包（off / 硬件简易 NSS / 软件 qosify）
if [ -d "$WORKSPACE/packages/qos-switch" ]; then
  rm -rf package/qos-switch
  cp -a "$WORKSPACE/packages/qos-switch" package/qos-switch
fi

# 机型定制文件注入（uci-defaults / sysctl 等），放在 feeds install 之前
if [ -d "$WORKSPACE/files" ]; then
  mkdir -p files
  cp -a "$WORKSPACE/files/." files/
  # git 在部分平台不保留可执行位，这里显式修正
  find files/etc/uci-defaults files/etc/init.d files/usr/sbin -type f -exec chmod 0755 {} + 2>/dev/null || true
fi

./scripts/feeds update -i -a
./scripts/feeds install -a
