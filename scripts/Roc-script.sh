#!/usr/bin/env bash
### 兆能M2 专用自定义脚本 ###
### 基于 openwrt-ci-roc Roc-script.sh 修改, 适配 zn_m2 无WiFi/无USB 场景 ###

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

# ===== 修改默认IP & 主机名 & 固件署名 =====
echo "==> 设置默认 IP 为 192.168.2.1, 主机名为 openwrt"
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='openwrt'/g" package/base-files/files/bin/config_generate

# 设置主机名映射
cat > package/base-files/files/etc/hosts <<'EOF'
127.0.0.1 localhost
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
127.0.0.1 openwrt
EOF

# LuCI 固件版本显示
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || { echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2; exit 1; }
sed -i "s#_('Firmware Version'), (L\.isObject(boardinfo\.release) ? boardinfo\.release\.description + ' / ' : '') + (luciversion || ''),# \
            _('Firmware Version'),\n \
            E('span', {}, [\n \
                (L.isObject(boardinfo.release)\n \
                ? boardinfo.release.description + ' / '\n \
                : '') + (luciversion || '') + ' /',\n \
            E('a', {\n \
                href: 'https://github.com/Wu140360/openwrt-ci-roc/releases',\n \
                target: '_blank',\n \
                rel: 'noopener noreferrer'\n \
                }, [ 'Built by ZNM2 $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# ===== 默认设置: 设备名 openwrt, 默认密码为空 (首次登录后设置) =====
# 修改 /etc/config/system 默认值
mkdir -p package/base-files/files/etc/config
cat > package/base-files/files/etc/config/system <<'EOF'
config system
    option hostname 'openwrt'
    option timezone 'Asia/Shanghai'
    option zonename 'Asia/Shanghai'
EOF

# ===== 禁用 WiFi 相关 (确保即使有驱动也不启用) =====
mkdir -p package/base-files/files/etc/config
cat > package/base-files/files/etc/config/wireless.disabled <<'EOF'
# WiFi disabled - this device (zn_m2) runs without wireless
# File intentionally empty to prevent wifi setup
EOF

# 创建 /etc/rc.local 禁用WiFi (防御性)
cat >> package/base-files/files/etc/rc.local <<'EOF'
# ZN-M2: Disable WiFi (no wireless hardware used)
# rm -rf /etc/config/wireless 2>/dev/null
# /etc/init.d/wpad disable 2>/dev/null
# /etc/init.d/hostapd disable 2>/dev/null
# true
EOF

# ===== 修改默认 LAN IP =====
cat > package/base-files/files/etc/config/network <<'EOF'
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd00:ab:cd::/48'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.2.1'
    option netmask '255.255.255.0'
    option ip6assign '60'
EOF

# ===== SmartDNS 预设配置 (解决GitHub DNS污染) =====
mkdir -p package/base-files/files/etc/config
cat > package/base-files/files/etc/config/smartdns <<'EOF'
config smartdns 'main'
    option enabled '1'
    option server_name 'openwrt'
    option port '53'
    option auto_set_dnsmasq '1'
    option dnsmasq_config '/etc/dnsmasq.conf'
    option redirect 'dnsmasq-upstream'
    option cache_size '512'
    option cache_dir '/tmp/smartdns'
    option prefetch_domain '1'
    option serve_expired '1'
    option serve_expired_ttl '259200'
    option serve_expired_reply_ttl '30'
    option dualstack_ip_selection '1'
    option force_aaaa_soa '0'
    option coredump '0'
    option bogus_nxdomain_ipv4 '220.181.57.217'
    option bogus_nxdomain_ipv4 '123.125.81.12'
    option log_level 'warn'
    option log_size '100K'
    option log_file '/tmp/smartdns.log'
    option tcp_server '0'
    option bind_tcp '0'
    option bind_device 'br-lan'

config server 'default'
    option address '223.5.5.5'
    option type 'udp'
    option port '53'
    option blacklist_ip '1'

config server 'default'
    option address '119.29.29.29'
    option type 'udp'
    option port '53'
    option blacklist_ip '1'

config server 'default'
    option address 'https://doh.pub/dns-query'
    option type 'https'
    option server_group 'domestic'

config server 'default'
    option address 'tls://223.5.5.5:853'
    option type 'tls'
    option server_group 'domestic'

config server 'default'
    option address 'https://dns.alidns.com/dns-query'
    option type 'https'
    option server_group 'domestic'

config server 'default'
    option address 'https://dns.google/dns-query'
    option type 'https'
    option server_group 'international'

config server 'default'
    option address 'tls://8.8.8.8:853'
    option type 'tls'
    option server_group 'international'

config server 'default'
    option address 'https://cloudflare-dns.com/dns-query'
    option type 'https'
    option server_group 'international'

### GitHub DNS 防污染规则 - 关键设置 ###
config domain-rule 'github'
    option domain 'github.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-raw'
    option domain 'raw.githubusercontent.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-assets'
    option domain 'objects.githubusercontent.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-avatars'
    option domain 'avatars.githubusercontent.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-api'
    option domain 'api.github.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-user'
    option domain 'user-images.githubusercontent.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-camo'
    option domain 'camo.githubusercontent.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'github-cloud'
    option domain 'github-cloud.s3.amazonaws.com'
    option server_group 'international'
    option no_speed_check '1'

config domain-rule 'google'
    option domain 'google.com'
    option server_group 'international'

config domain-rule 'youtube'
    option domain 'youtube.com'
    option server_group 'international'

config domain-rule 'telegram'
    option domain 'telegram.org'
    option server_group 'international'

### 国内域名加速 ###
config domain-rule 'cn'
    option domain 'cn'
    option server_group 'domestic'

config domain-rule 'baidu'
    option domain 'baidu.com'
    option server_group 'domestic'

config domain-rule 'qq'
    option domain 'qq.com'
    option server_group 'domestic'

config domain-rule 'taobao'
    option domain 'taobao.com'
    option server_group 'domestic'

config domain-rule 'aliyun'
    option domain 'aliyun.com'
    option server_group 'domestic'

### 强制使用TCP查询的域名 (防UDP污染) ###
config force-qtype-SOA 'default'
    option qtype '1'
    option is_ipv4 '1'
    list domain 'github.com'
    list domain 'raw.githubusercontent.com'
    list domain 'objects.githubusercontent.com'
EOF

# ===== qosify NSS 硬件QoS 预设配置 =====
cat > package/base-files/files/etc/config/qosify <<'EOF'
config qosify 'settings'
    option enabled '0'
    option download '1000mbit'
    option upload '1000mbit'
    option script 'simple.qosify'
    option interface 'wan'
    option ingress 'wan'
    option egress 'wan'
    option options '-6'
    option debug '0'
    option autorate_ingress '1'
    option autorate_egress '1'

config interface 'wan'
    option name 'wan'
    option disabled '0'
    option bandwidth_up '100mbit'
    option bandwidth_down '1000mbit'
    option overhead_type 'ether-vlan'
    option options 'diffserv4'
    option autorate '1'
    option ingress '1'
    option egress '1'

config class 'Default'
    option ingress 'CS0'
    option egress 'CS0'
    option priority '3'
    option fallback '1'

config class 'Priority'
    option ingress 'CS5'
    option egress 'CS5'
    option priority '1'

config class 'Normal'
    option ingress 'CS3'
    option egress 'CS3'
    option priority '2'

config class 'Bulk'
    option ingress 'CS1'
    option egress 'CS1'
    option priority '4'

config rule 'SSH'
    option klass 'Priority'
    option dport '22'
    option proto 'tcp'

config rule 'DNS'
    option klass 'Priority'
    option dport '53'
    option proto 'udp'

config rule 'Gaming'
    option klass 'Priority'
    option dport '3074,27015-27200'
    option proto 'udp'

config rule 'Web'
    option klass 'Normal'
    option dport '80,443'
    option proto 'tcp'

config rule 'Download'
    option klass 'Bulk'
    option dport '6881-6999,51413'
    option proto 'tcp'
EOF

# 启用 NSS 队列规则 (qca-nss-qdisc)
mkdir -p package/base-files/files/etc/modules.d
cat > package/base-files/files/etc/modules.d/99-nss-qdisc <<'EOF'
qca-nss-qdisc
EOF

# ===== TTYD 终端配置 (集成常用工具别名) =====
mkdir -p package/base-files/files/etc/profile.d
cat > package/base-files/files/etc/profile.d/ttyd-tools.sh <<'EOF'
#!/bin/sh
### TTYD 终端常用工具别名与函数 ###

alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias df='df -h'
alias free='free -h'
alias top='htop'
alias gs='git status'
alias gp='git pull'
alias gc='git clone'
alias ports='netstat -tulpen'
alias conns='ss -tnp'
alias myip='curl -s ifconfig.me'
alias myipv6='curl -s6 ifconfig.me'
alias ns='nslookup'
alias digg='dig +short'
alias speed='speedtest-cli 2>/dev/null || echo "speedtest-cli not installed"'
alias temp='cat /sys/class/thermal/thermal_zone*/temp'
alias cpu='cat /proc/cpuinfo | grep "model name" | head -1'
alias meminfo='cat /proc/meminfo | head -10'
alias ifstat='ifstat -t 1'
alias routes='ip route show'
alias arp='ip neigh show'
alias fw='iptables -L -n -v'
alias fw6='ip6tables -L -n -v'
alias nss='lsmod | grep nss'
alias zram='cat /proc/swaps'

### 网络诊断函数 ###
diag() {
    echo "=== 系统信息 ==="
    uname -a
    echo ""
    echo "=== CPU 温度 ==="
    for i in /sys/class/thermal/thermal_zone*/temp; do
        echo "$i: $(cat $i 2>/dev/null | awk '{print $1/1000"°C"}')"
    done
    echo ""
    echo "=== 内存使用 ==="
    free -h
    echo ""
    echo "=== 磁盘使用 ==="
    df -h
    echo ""
    echo "=== 网络接口 ==="
    ip -br addr show
    echo ""
    echo "=== NSS 模块状态 ==="
    lsmod | grep -i nss || echo "NSS modules not loaded"
    echo ""
    echo "=== DNS 测试 ==="
    nslookup github.com 2>/dev/null || echo "DNS not configured"
}

dns_test() {
    echo "=== DNS 解析测试 ==="
    for domain in github.com raw.githubusercontent.com google.com baidu.com; do
        echo -n "$domain -> "
        nslookup "$domain" 127.0.0.1 2>/dev/null | grep "Address" | tail -1
    done
}

watch_conn() {
    watch -n 1 'ss -tnp | head -30'
}

clear_cache() {
    echo 3 > /proc/sys/vm/drop_caches
    echo "Cache cleared"
}
EOF
chmod +x package/base-files/files/etc/profile.d/ttyd-tools.sh

# ===== CPU 频率调节预设 (性能模式, 高负载稳定) =====
cat > package/base-files/files/etc/config/cpufreq <<'EOF'
config 'cpufreq' 'settings'
    option 'enabled' '1'
    option 'governor' 'schedutil'
    option 'min_freq' '0'
    option 'max_freq' '0'
    option 'up_threshold' '50'
    option 'down_threshold' '20'
EOF

# ===== UPnP 预设 =====
cat > package/base-files/files/etc/config/upnpd <<'EOF'
config upnpd 'config'
    option enabled '1'
    option enable_natpmp '1'
    option enable_upnp '1'
    option secure_mode '1'
    option log_output '0'
    option download '1024'
    option upload '512'
    option internal_iface 'lan'
    option external_iface 'wan'
    option port '5000'
    option upnp_lease_file '/var/run/miniupnpd.leases'

config perm_rule 'AllowHighPorts'
    option action 'allow'
    option ext_ports '1024-65535'
    option int_addr '0.0.0.0/0'
    option int_ports '1024-65535'
    option comments 'Allow high ports'
EOF

# ===== DDNS 预设 (Cloudflare 示例, 用户需自行填写) =====
cat > package/base-files/files/etc/config/ddns <<'EOF'
config ddns 'global'
    option ddns_dateformat '%F %R'
    option ddns_rundir '/var/run/ddns'

config service 'myddns_ipv4'
    option enabled '0'
    option interface 'wan'
    option service_name 'cloudflare.com-v4'
    option lookup_host ''
    option domain ''
    option username 'Bearer'
    option password ''
    option use_ipv6 '0'
    option use_syslog '2'
    option check_interval '10'
    option check_unit 'min'
    option update_interval '1'
    option update_unit 'day'
    option retry_interval '60'
    option retry_unit 'sec'

config service 'myddns_ipv6'
    option enabled '0'
    option interface 'wan'
    option service_name 'cloudflare.com-v6'
    option lookup_host ''
    option domain ''
    option username 'Bearer'
    option password ''
    option use_ipv6 '1'
    option use_syslog '2'
    option check_interval '10'
    option check_unit 'min'
    option update_interval '1'
    option update_unit 'day'
    option retry_interval '60'
    option retry_unit 'sec'
EOF

# ===== KMS 预设 (默认启用) =====
cat > package/base-files/files/etc/config/vlmcsd <<'EOF'
config vlmcsd 'config'
    option enabled '1'
    option port '1688'
    option iface 'lan'
    option lan_interface 'br-lan'
    option ip_address '192.168.2.1'
    option DisableGenID '0'
    option DisabledIPRouting '0'
EOF

# ===== WireGuard 预设 (用户需自行配置接口和peer) =====
cat > package/base-files/files/etc/config/wireguard <<'EOF'
# WireGuard 默认禁用, 用户通过 LuCI 或命令行配置
# 示例配置 (取消注释后使用):
# config interface 'wg0'
#     option proto 'wireguard'
#     option private_key ''
#     option listen_port '51820'
#     list addresses '10.0.0.1/24'
#
# config wireguard_wg0 'peer_name'
#     option public_key ''
#     option allowed_ips '10.0.0.2/32'
#     option endpoint_host ''
#     option endpoint_port '51820'
#     option persistent_keepalive '25'
EOF

# ===== 内核参数优化 (网络性能) =====
cat > package/base-files/files/etc/sysctl.conf <<'EOF'
# ZN-M2 网络性能优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.core.somaxconn = 4096
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# 内存优化 (1GB)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF

# ===== Git稀疏克隆 (仅克隆需要的包) =====
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

### Aurora 主题 (唯一主题) ###
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

### qosify (NSS硬件QoS) ###
if package_enabled qosify luci-app-qosify; then
  rm -rf feeds/packages/net/qosify
  git_sparse_clone master https://github.com/openwrt/packages net/qosify
  mv package/qosify feeds/packages/net/qosify
fi

### SmartDNS ###
if package_enabled luci-app-smartdns smartdns; then
  rm -rf feeds/packages/net/smartdns
  git_sparse_clone master https://github.com/openwrt/packages net/smartdns
  mv package/smartdns feeds/packages/net/smartdns
fi

### DDNS (Cloudflare支持) ###
if package_enabled luci-app-ddns ddns-scripts ddns-scripts-cloudflare; then
  rm -rf feeds/packages/net/ddns-scripts
  git_sparse_clone master https://github.com/openwrt/packages net/ddns-scripts
  mv package/ddns-scripts feeds/packages/net/ddns-scripts
fi
if package_enabled luci-app-ddns; then
  rm -rf feeds/luci/applications/luci-app-ddns
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-ddns
  mv package/luci-app-ddns feeds/luci/applications/luci-app-ddns
fi

### TTYD ###
if package_enabled luci-app-ttyd ttyd; then
  rm -rf feeds/luci/applications/luci-app-ttyd
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-ttyd
  mv package/luci-app-ttyd feeds/luci/applications/luci-app-ttyd
fi

### UPnP ###
if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/openwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

### vlmcsd (KMS) ###
if package_enabled luci-app-vlmcsd vlmcsd; then
  rm -rf feeds/packages/net/vlmcsd
  git_sparse_clone master https://github.com/openwrt/packages net/vlmcsd
  mv package/vlmcsd feeds/packages/net/vlmcsd
fi
if package_enabled luci-app-vlmcsd; then
  rm -rf feeds/luci/applications/luci-app-vlmcsd
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-vlmcsd
  mv package/luci-app-vlmcsd feeds/luci/applications/luci-app-vlmcsd
fi

### TurboACC ###
if package_enabled luci-app-turboacc; then
  rm -rf feeds/luci/applications/luci-app-turboacc
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-turboacc
  mv package/luci-app-turboacc feeds/luci/applications/luci-app-turboacc
fi

### cpufreq ###
if package_enabled luci-app-cpufreq; then
  rm -rf feeds/luci/applications/luci-app-cpufreq
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-cpufreq
  mv package/luci-app-cpufreq feeds/luci/applications/luci-app-cpufreq
fi

### WireGuard (通常已在kernel中, 确保LuCI app) ###
if package_enabled luci-app-wireguard; then
  rm -rf feeds/luci/applications/luci-app-wireguard
  git_sparse_clone master https://github.com/openwrt/luci applications/luci-app-wireguard
  mv package/luci-app-wireguard feeds/luci/applications/luci-app-wireguard
fi

### 清理不需要的 feeds (减少编译时间和固件体积) ###
./scripts/feeds update -i -a
./scripts/feeds install -a
