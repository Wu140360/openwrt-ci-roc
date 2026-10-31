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
	grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >>"$THIRD_PARTY_SOURCES_FILE"
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
printf 'Repository\tBranch\tCommit\n' >"$THIRD_PARTY_SOURCES_FILE"

# Default LAN address, firmware hostname and LuCI build attribution.
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='ZN-M2'/g" package/base-files/files/bin/config_generate
luci_system_js="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
firmware_version_anchor="_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),"
grep -Fq "$firmware_version_anchor" "$luci_system_js" || {
	echo "Error: LuCI firmware version anchor was not found in $luci_system_js" >&2
	exit 1
}
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
                }, [ 'Built by Wu140360 $(date "+%Y-%m-%d %H:%M:%S")' ])\n \
            ]),#" "$luci_system_js"

# Keep q6_region at the ipq6018-512m.dtsi default of 55MB (0x3700000).
# The optional reductions to 16/32/64/96MB are deliberately left disabled:
# WiFi is not built, but the stock reserved-memory layout is kept untouched.
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x01000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x02000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi
# sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x06000000>/' target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi

# Optional 1.5GHz CPU voltage bump (0.9375V -> 0.95V), disabled by default.
# sed -i 's/opp-microvolt = <937500>;/opp-microvolt = <950000>;/' target/linux/qualcommax/patches-6.12/0038-v6.16-arm64-dts-qcom-ipq6018-add-1.5GHz-CPU-Frequency.patch

# Git sparse clone helper: clone only the requested directories into package/.
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

# UPnP: use the immortalwrt 25.12 versions for both the daemon and LuCI app.
if package_enabled luci-app-upnp miniupnpd; then
	rm -rf feeds/packages/net/miniupnpd
	git_sparse_clone openwrt-25.12 https://github.com/immortalwrt/packages net/miniupnpd
	mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
	rm -rf feeds/luci/applications/luci-app-upnp
	git_sparse_clone openwrt-25.12 https://github.com/immortalwrt/luci applications/luci-app-upnp
	mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

# Aurora theme and its configuration application.
if package_enabled luci-theme-aurora luci-app-aurora-config; then
	rm -rf feeds/luci/themes/luci-theme-aurora
	clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
	rm -rf feeds/luci/applications/luci-app-aurora-config
	clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

# lucky (wanji): keep PKG_VERSION/SOURCE_URL/HASH untouched, only change the
# asset name to the wanji build. A local archive matching the Makefile version
# is copied into dl/ so cloud builds do not depend on the release asset.
if package_enabled luci-app-lucky lucky; then
	clone_repository https://github.com/gdy666/luci-app-lucky main package/luci-app-lucky

	lucky_makefile="package/luci-app-lucky/lucky/Makefile"
	[ -f "$lucky_makefile" ] || {
		echo "Error: lucky Makefile not found: $lucky_makefile" >&2
		exit 1
	}

	if ! grep -Fq '_wanji.tar.gz' "$lucky_makefile"; then
		# shellcheck disable=SC2016  # Make variables are intentionally literal here.
		sed -i 's#^PKG_SOURCE:=lucky_.*\.tar\.gz$#PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_wanji.tar.gz#' "$lucky_makefile"
	fi
	# shellcheck disable=SC2016  # Make variables are intentionally literal here.
	grep -Fq 'PKG_SOURCE:=lucky_$(PKG_VERSION)_Linux_$(LUCKY_ARCH)_wanji.tar.gz' "$lucky_makefile" || {
		echo "Error: failed to switch lucky to the wanji asset in $lucky_makefile" >&2
		exit 1
	}

	lucky_version="$(sed -n 's/^PKG_VERSION:=//p' "$lucky_makefile" | head -n 1)"
	[ -n "$lucky_version" ] || {
		echo "Error: lucky PKG_VERSION is empty" >&2
		exit 1
	}
	echo "lucky version: $lucky_version (wanji asset)"

	mkdir -p dl
	lucky_archives=()
	for candidate_dir in "$WORKSPACE/custom/lucky" "$WORKSPACE/files/lucky" "$WORKSPACE/lucky"; do
		[ -d "$candidate_dir" ] || continue
		while IFS= read -r archive; do
			[ -n "$archive" ] && lucky_archives+=("$archive")
		done < <(find "$candidate_dir" -maxdepth 1 -type f -name "lucky_${lucky_version}_Linux_*_wanji.tar.gz" -print)
	done

	if [ "${#lucky_archives[@]}" -gt 0 ]; then
		for archive in "${lucky_archives[@]}"; do
			gzip -t "$archive" || {
				echo "Error: corrupt lucky archive: $archive" >&2
				exit 1
			}
			cp -f "$archive" "dl/$(basename "$archive")"
			echo "Using local lucky wanji archive: $(basename "$archive")"
		done
	else
		echo "No local lucky ${lucky_version} wanji archive; make download will fetch it from the official release."
	fi
fi

# Self-built LuCI QoS mode switch and rootfs defaults. Both must be in place
# before the final feeds update/install at the end of this script.
rm -rf package/luci-app-qos-switch
cp -a "$WORKSPACE/custom/package/luci-app-qos-switch" package/
chmod +x package/luci-app-qos-switch/root/etc/init.d/qosswitch \
	package/luci-app-qos-switch/root/usr/sbin/qos-switch

mkdir -p files
cp -a "$WORKSPACE/custom/files/." files/
chmod +x files/etc/uci-defaults/30-zn-m2

./scripts/feeds update -i -a
./scripts/feeds install -a
