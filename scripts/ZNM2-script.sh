#!/usr/bin/env bash
###############################################################################
## ZNM2-script.sh - 兆能M2 专用DIY脚本
## 基于 Roc-script.sh 修改, 适配 zn_m2 (IPQ60XX, 无WiFi, 无USB, 满血NSS)
## 该脚本在OpenWrt源码目录中执行, 负责:
##   1. 修改默认IP/主机名/固件信息
##   2. 克隆第三方软件包 (仅按需)
##   3. 安装feeds
###############################################################################
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

###############################################################################
## 1. 修改默认IP & 主机名 & 固件署名
###############################################################################
echo "==> Setting default IP to 192.168.2.1, hostname to openwrt"

# 修改默认LAN IP
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# 修改主机名为 openwrt (用户要求)
sed -i "s/hostname='.*'/hostname='openwrt'/g" package/base-files/files/bin/config_generate

# 修改默认时区为 Asia/Shanghai
sed -i "s/timezone='.*'/timezone='CST-8'/g" package/base-files/files/bin/config_generate

# 固件版本信息添加编译署名
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
                  }, [ 'ZNM2 Build by Wu140360 $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
              ]),#" "$luci_system_js"
  fi
fi

###############################################################################
## 2. NSS q6_region 内存 - 保持默认, 不缩减 (用户要求满血NSS)
##    注释掉的sed行为参考, 不执行任何修改
###############################################################################
echo "==> NSS q6_region: keeping default (no modification for full NSS)"

###############################################################################
## 3. 按需克隆第三方软件包
##    仅克隆配置中启用的包, 减少编译时间和体积
###############################################################################

# Git稀疏克隆函数
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

# --- Aurora 主题 (用户指定使用Aurora) ---
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  echo "==> Cloning Aurora theme"
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  echo "==> Cloning Aurora config"
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

# --- SmartDNS ---
if package_enabled luci-app-smartdns smartdns; then
  echo "==> SmartDNS is in feeds, no extra clone needed"
fi

# --- qosify (NSS QoS) ---
if package_enabled luci-app-qosify qosify; then
  echo "==> qosify is in feeds, no extra clone needed"
fi

# --- WireGuard (在feeds中) ---
if package_enabled luci-app-wireguard wireguard-tools; then
  echo "==> WireGuard is in feeds, no extra clone needed"
fi

###############################################################################
## 4. 设置默认主题和默认包管理器
###############################################################################
echo "==> Setting Aurora as default theme"

# 在uci-defaults中设置默认主题为Aurora
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-znm2-defaults <<'UCIEOF'
#!/bin/sh
# 兆能M2 默认设置

# 设置默认主题
uci set luci.main.mediaurlbase='/luci-static/aurora'
uci commit luci

# 设置主机名
uci set system.@system[0].hostname='openwrt'
uci commit system

# 设置默认语言为简体中文
uci set luci.main.lang='zh_cn'
uci commit luci

# SmartDNS 默认配置 (解决GitHub DNS污染)
# 使用多个上游DNS, 优先IPv6
if [ -f /etc/config/smartdns ]; then
  uci set smartdns.@smartdns[0].enabled='1'
  uci set smartdns.@smartdns[0].port='53'
  uci set smartdns.@smartdns[0].server_group='default'
  # 腾讯DNSPod (支持DoT/DoH)
  uci add_list smartdns.smartdns_server='tls://dot.pub:853'
  uci add_list smartdns.smartdns_server='tls://223.5.5.5:853'
  uci add_list smartdns.smartdns_server='https://doh.pub/dns-query'
  # Cloudflare (IPv6)
  uci add_list smartdns.smartdns_server='tls://[2606:4700:4700::1111]:853'
  uci add_list smartdns.smartdns_server='tls://[2606:4700:4700::1001]:853'
  # Google (IPv6)
  uci add_list smartdns.smartdns_server='tls://[2001:4860:4860::8888]:853'
  # 国内DNS用于分流
  uci add_list smartdns.smartdns_server='udp://114.114.114.114:53'
  uci set smartdns.@smartdns[0].dualstack_ip_selection='1'
  uci set smartdns.@smartdns[0].prefetch_domain='1'
  uci set smartdns.@smartdns[0].serve_expired='1'
  uci set smartdns.@smartdns[0].cache_size='1024'
  uci set smartdns.@smartdns[0].cache_persist_time='24h'
  # 强制所有DNS查询走SmartDNS (解决DNS污染)
  uci set smartdns.@smartdns[0].force_aaaa='0'
  uci commit smartdns
fi

# qosify 默认配置 (NSS QoS)
# 使用nss.qdisc作为根qdisc, 实现硬件加速QoS
if [ -f /etc/config/qosify ]; then
  uci set qosify.@defaults[0].defaults='defaults'
  # 使用 NSS qdisc (如果可用), 否则回退到cake
  uci set qosify.@defaults[0].qdisc='nss.qdisc'
  uci set qosify.@defaults[0].qdisc_fallback='cake'
  uci set qosify.@defaults[0].qdisc_args='flows target 5ms interval 100ms quantum 1514'
  # 默认带宽 (用户需根据实际宽带修改)
  # 此处设置合理默认值, 用户可在WebUI中调整
  uci set qosify.@defaults[0].bandwidth_up='50mbit'
  uci set qosify.@defaults[0].bandwidth_down='500mbit'
  # 优先保障游戏/语音/视频会议等实时流量
  uci add_list qosify.@defaults[0].prioritize='tcp:443'    # HTTPS
  uci add_list qosify.@defaults[0].prioritize='udp:443'    # QUIC/HTTP3
  uci add_list qosify.@defaults[0].prioritize='udp:53'     # DNS
  uci add_list qosify.@defaults[0].prioritize='tcp:53'     # DNS
  uci add_list qosify.@defaults[0].prioritize='udp:500,4500' # IPSec/IKE
  uci add_list qosify.@defaults[0].prioritize='udp:51820'  # WireGuard
  # 降低大流量下载的优先级
  uci add_list qosify.@defaults[0].bulk='tcp:80'          # HTTP
  uci commit qosify
fi

# TTYD 默认配置 (启用终端, 集成常用工具)
if [ -f /etc/config/ttyd ]; then
  uci set ttyd.@ttyd[0].enabled='1'
  uci set ttyd.@ttyd[0].interface='@local'
  uci set ttyd.@ttyd[0].port='7681'
  uci set ttyd.@ttyd[0].command='/bin/bash'
  uci set ttyd.@ttyd[0].username='root'
  uci commit ttyd
fi

# UPnP 默认启用
if [ -f /etc/config/upnp ]; then
  uci set upnpd.@upnpd[0].enabled='1'
  uci set upnpd.@upnpd[0].enable_natpmp='1'
  uci set upnpd.@upnpd[0].enable_upnp='1'
  uci commit upnpd
fi

# 禁用IPv6 SLAAC临时地址 (家庭路由场景)
sysctl -w net.ipv6.conf.all.use_tempaddr=0 2>/dev/null || true

exit 0
UCIEOF
chmod +x package/base-files/files/etc/uci-defaults/99-znm2-defaults

###############################################################################
## 5. 确保精简: 移除不需要的feeds包 (防止依赖拉入)
###############################################################################
echo "==> Cleaning up unused packages from feeds"

# 移除Argon主题 (使用Aurora, 不重复)
rm -rf feeds/luci/themes/luci-theme-argon 2>/dev/null || true

# 移除不需要的LuCI应用 (精简体积)
for app in \
  luci-app-passwall \
  luci-app-passwall2 \
  luci-app-openclash \
  luci-app-lucky \
  luci-app-oaf \
  luci-app-wechatpush \
  luci-app-openlist2 \
  luci-app-gecoosac \
  luci-app-samba4 \
  luci-app-diskman \
  luci-app-hd-idle \
  luci-app-3cat \
  luci-app-athena-led \
  luci-app-argon-config \
  luci-app-banip \
  luci-app-arpbind \
  luci-app-usb-printer \
  luci-app-wifischedule \
  luci-app-sqm \
  luci-app-frpc \
  luci-app-frps \
  luci-app-aria2 \
  luci-app-ttyd \
  ; do
  rm -rf "feeds/luci/applications/$app" 2>/dev/null || true
done

###############################################################################
## 6. 更新并安装feeds
###############################################################################
echo "==> Updating and installing feeds"
./scripts/feeds update -i -a
./scripts/feeds install -a

echo "==> ZNM2-script.sh completed successfully"
