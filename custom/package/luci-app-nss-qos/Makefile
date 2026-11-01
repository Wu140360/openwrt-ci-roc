#
# LuCI NSS hardware QoS for Qualcomm IPQ60xx NSS builds
#
include $(TOPDIR)/rules.mk

LUCI_TITLE:=NSS hardware QoS (nsstbl / nssfq_codel / nssmirred)
LUCI_DESCRIPTION:=Configure NSS hardware shaping on the WAN device: nsstbl + nssfq_codel for egress and ifb + nssmirred for ingress. ECM stays enabled.
LUCI_DEPENDS:=+luci-base +kmod-qca-nss-drv-qdisc +kmod-qca-nss-drv-igs +kmod-ifb +tc-full +ip-full
LUCI_PKGARCH:=all
LUCI_MINIFY_JS:=0

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Wu140360

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
