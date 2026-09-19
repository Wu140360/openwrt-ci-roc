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
        if (values[i] == package_name) { found = 1 }
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
  local target_dir="$1" attempt
  shift
  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then return 0; fi
    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT)" >&2
      sleep $((attempt * 2))
    fi
  done
  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1" branch="$2" checkout_dir="$3" commit revision
  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1" branch="$2" target_dir="$3"
  clone_with_retry "$target_dir" --depth=1 --no-tags --branch "$branch" --single-branch "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# 1. 修改默认IP为192.168.2.1，主机名为openwrt
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='openwrt'/g" package/base-files/files/bin/config_generate

# 2. 固件版本信息
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor not found" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\
            E('span', {}, [\
                (L.isObject(boardinfo.release)\
                ? boardinfo.release.description + ' / '\
                : '') + (luciversion || '') + ' / ',\
            E('a', {\
                href: 'https://github.com/Wu140360/openwrt-ci-roc/releases',\
                target: '_blank',\
                rel: 'noopener noreferrer'\
                }, [ 'Built by Wu140360 $(date "+%Y-%m-%d %H:%M:%S")' ])\
            ]),#" "$luci_system_js"

# 3. SmartDNS 防DNS污染预设配置
mkdir -p files/etc/config
cat > files/etc/config/smartdns << 'SMARTDNS_EOF'
config smartdns
    option enable '1'
    option port '53'
    option auto_set_dnsmasq '1'
    option prefetch_domain '1'
    option serve_expired '1'
    option cache_size '4096'
    option resolve_local_hostnames '0'
    option dualstack_ip_selection '1'
    option bind_device 'br-lan'
    option tcp_server '1'
    option tcp_port '53'

config server 'github'
    option name 'dns.google'
    option server '8.8.8.8'
    option type 'udp'
    option port '53'

config server 'github_dot'
    option name 'cloudflare-dns'
    option server '1.1.1.1'
    option type 'dot'
    option port '853'

config server 'github_doh'
    option name 'cloudflare-doh'
    option server 'https://cloudflare-dns.com/dns-query'
    option type 'https'

config domain-rule 'github_rule'
    option domain 'github.com,githubusercontent.com,githubassets.com,api.github.com,raw.githubusercontent.com,codeload.github.com'
    option server 'cloudflare-doh'
    option force '1'

config domain-rule 'cdn_check'
    option domain 'fastly.net,akamai.net,akamaiedge.net'
    option server 'cloudflare-doh'
    option force '1'
SMARTDNS_EOF

# 4. 性能优化：内核参数
mkdir -p files/etc/sysctl.d
cat > files/etc/sysctl.d/99-znm2-performance.conf << 'SYSCTL_EOF'
# TCP BBR + 性能优化
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=16384
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.netfilter.nf_conntrack_max=655360
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=60
SYSCTL_EOF

# 5. qosify 默认配置（不启用，需用户填入带宽后手动启用）
mkdir -p files/etc/config
cat > files/etc/config/qosify << 'QOSIFY_EOF'
config defaults
    option enabled '0'
    option dscp_icmp 'CS0'
    option dscp_management 'CS4'
    option dscp_low_prio 'CS1'
    option dscp_default_tcp 'CS0'
    option dscp_default_udp 'CS4'
    option bulk_trigger_timeout '30'
    option bulk_trigger_pps '1000'

config interface 'wan'
    option name 'wan'
    option disabled '1'
QOSIFY_EOF

# 6. ttyd 默认配置 + 终端工具别名
mkdir -p files/etc/config
cat > files/etc/config/ttyd << 'TTYD_EOF'
config ttyd
    option interface '@lan'
    option port '7681'
    option debug '0'
    option readonly '0'
    option terminal_type 'xterm-256color'
    option username 'root'
TTYD_EOF

# shell aliases for ttyd
mkdir -p files/etc/profile.d
cat > files/etc/profile.d/znm2-aliases.sh << 'ALIAS_EOF'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias df='df -h'
alias free='free -h'
alias dmesg='dmesg --color=always'
alias zram='cat /proc/swaps && echo && free -h'
alias nss='dmesg | grep -i nss | tail -20'
alias temp='cat /sys/class/thermal/thermal_zone*/temp'
alias cpu='cat /proc/cpuinfo | grep -i mhz'
alias ifstat='ip -s link'
alias myip='curl -s ifconfig.me && echo'
alias myip6='curl -s 6.ifconfig.me && echo'
alias speed='iperf3 -c ping.online.net -t 10'
alias pscpu='ps aux --sort=-%cpu | head -20'
alias psmem='ps aux --sort=-%mem | head -20'
alias netstat='ss -tunap'
alias ns='nslookup'
alias digg='dig +short'
alias wg='wg show'
alias smartdns='/etc/init.d/smartdns'
alias qos='qosify status'
alias nft='nft list ruleset'
alias conn='cat /proc/sys/net/netfilter/nf_conntrack_count'
ALIAS_EOF
chmod +x files/etc/profile.d/znm2-aliases.sh

# 7. NSS 状态检查脚本
mkdir -p files/usr/bin
cat > files/usr/bin/nss-status << 'NSS_EOF'
#!/bin/sh
echo "=== NSS Status ==="
echo "NSS Firmware:"
lsmod | grep nss
echo ""
echo "NSS Memory:"
cat /proc/meminfo | grep -i zram
echo ""
echo "NSS Logs (last 10):"
dmesg | grep -i "nss\|qca" | tail -10
echo ""
echo "Network Offload:"
cat /proc/interrupts | grep -i nss
NSS_EOF
chmod +x files/usr/bin/nss-status

# 8. WireGuard 快速配置脚本
mkdir -p files/usr/bin
cat > files/usr/bin/wg-quick-peer << 'WGEOF'
#!/bin/sh
if [ -z "$1" ]; then
  echo "Usage: wg-quick-peer <peer_public_key> [endpoint] [allowed_ips]"
  echo "Example: wg-quick-peer <pubkey> 1.2.3.4:51820 0.0.0.0/0"
  exit 1
fi
PEER_KEY="$1"
ENDPOINT="${2:-}"
ALLOWED_IPS="${3:-0.0.0.0/0,::/0}"
WG_IF="wg0"
WG_PORT="51820"
WG_NET="10.0.0.1/24"
umask 077
mkdir -p /etc/wireguard
if [ ! -f "/etc/wireguard/${WG_IF}.key" ]; then
  wg genkey > "/etc/wireguard/${WG_IF}.key"
  wg pubkey < "/etc/wireguard/${WG_IF}.key" > "/etc/wireguard/${WG_IF}.pub"
fi
PRIV_KEY=$(cat "/etc/wireguard/${WG_IF}.key")
cat > "/etc/wireguard/${WG_IF}.conf" << EOF
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${WG_NET}
ListenPort = ${WG_PORT}
PostUp = nft add table ip wireguard; nft add chain ip wireguard forward { type filter hook forward priority 0 \; }; nft add rule ip wireguard forward iifname ${WG_IF} accept
PostDown = nft delete table ip wireguard

[Peer]
PublicKey = ${PEER_KEY}
AllowedIPs = ${ALLOWED_IPS}
EOF
if [ -n "$ENDPOINT" ]; then
  sed -i "/AllowedIPs/a Endpoint = ${ENDPOINT}" "/etc/wireguard/${WG_IF}.conf"
fi
echo "WireGuard config written to /etc/wireguard/${WG_IF}.conf"
echo "Public key: $(cat /etc/wireguard/${WG_IF}.pub)"
echo "Start with: wg-quick up ${WG_IF}"
WGEOF
chmod +x files/usr/bin/wg-quick-peer

# 9. feeds 更新
./scripts/feeds update -i -a
./scripts/feeds install -a
