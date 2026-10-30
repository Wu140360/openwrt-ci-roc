# SPDX-License-Identifier: GPL-2.0-only
#
# qos-switch: 兆能 M2 三态 QoS 一键切换
#   off    : 关闭所有整形，ECM/NSS 满血硬件加速
#   nss    : 硬件简易 QoS（nss-ifb + nsstbl + nssfq_codel，实验）
#   qosify : 软件多功能 QoS（qosify eBPF + CAKE，需停 ECM）
#
# 本包为架构无关的脚本包，由 scripts/Roc-script.sh 复制到 $OPENWRT_PATH/package/qos-switch。

include $(TOPDIR)/rules.mk

PKG_NAME:=qos-switch
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/qos-switch
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=QoS
  TITLE:=QoS mode switcher (off / NSS hardware / qosify software)
  DEPENDS:=+luci-base +luci-compat +luci-lib-nixio +lua \
	+tc-full +kmod-ifb +kmod-sched-core \
	+qosify +sqm-scripts +sqm-scripts-nss \
	+kmod-qca-nss-drv-qdisc +kmod-qca-nss-drv-igs +kmod-nss-ifb
endef

define Package/qos-switch/description
  Three mutually exclusive QoS modes for ZN-M2 (IPQ6000):
  off (full hardware NSS acceleration), nss (NSS ingress/egress shaper,
  experimental) and qosify (eBPF + CAKE software shaping with ECM stopped).
  A LuCI page is included so the mode can be switched with one click.
endef

define Package/qos-switch/conffiles
/etc/config/qosmode
endef

define Build/Compile
endef

define Package/qos-switch/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/qosmode $(1)/etc/config/qosmode
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/qos-switch $(1)/etc/init.d/qos-switch
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/qos-switch $(1)/usr/sbin/qos-switch
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/qos-switch.lua $(1)/usr/lib/lua/luci/controller/qos-switch.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/qos-switch.lua $(1)/usr/lib/lua/luci/model/cbi/qos-switch.lua
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-qos-switch.json $(1)/usr/share/luci/menu.d/luci-app-qos-switch.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-qos-switch.json $(1)/usr/share/rpcd/acl.d/luci-app-qos-switch.json
	$(INSTALL_DIR) $(1)/usr/share/qos-switch/po/zh_Hans
	$(INSTALL_DATA) ./po/zh_Hans/qos-switch.po $(1)/usr/share/qos-switch/po/zh_Hans/qos-switch.po
endef

$(eval $(call BuildPackage,qos-switch))
