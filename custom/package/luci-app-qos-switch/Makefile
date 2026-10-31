#
# LuCI QoS mode switch for ZN M2 / NSS builds
#
include $(TOPDIR)/rules.mk

LUCI_TITLE:=QoS mode switch (NSS hardware / software / off)
LUCI_DESCRIPTION:=One-click switch between NSS hardware shaping, software SQM/eqos and QoS off. Software mode stops ECM hardware offload so the CPU shaper is effective.
LUCI_DEPENDS:=+luci-base +luci-app-sqm +luci-app-eqos +sqm-scripts +tc +kmod-sched-core +kmod-ifb
LUCI_PKGARCH:=all
LUCI_MINIFY_JS:=0

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Wu140360

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
