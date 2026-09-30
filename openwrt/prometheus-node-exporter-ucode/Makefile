include $(TOPDIR)/rules.mk

PKG_NAME:=prometheus-node-exporter-ucode
# Date versions, as the feed package this replaces: a lower one would lose to it on upgrade.
PKG_VERSION:=2026.09.30
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE NOTICE
PKG_MAINTAINER:=António Mora <m00qek@gmail.com>

include $(INCLUDE_DIR)/package.mk

COLLECTORS_DIR:=/usr/share/ucode/node_exporter/collectors

# Installed with the exporter itself; every other collector is a subpackage.
BASE_COLLECTORS:=conntrack cpu entropy filefd loadavg meminfo

define Package/$(PKG_NAME)/Default
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Prometheus node exporter
  PKGARCH:=all
endef

define Package/$(PKG_NAME)
  $(call Package/$(PKG_NAME)/Default)
  DEPENDS:=+uhttpd +uhttpd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-rtnl
endef

define Package/$(PKG_NAME)/description
  Node metrics for Prometheus, served by uhttpd at /metrics. A rewrite in ucode
  of the node exporters for OpenWrt; each optional collector is a subpackage.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/$(PKG_NAME)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/node_exporter $(1)$(COLLECTORS_DIR)
	$(INSTALL_DATA) ./src/node_exporter/*.uc $(1)/usr/share/ucode/node_exporter/
	$(foreach c,$(BASE_COLLECTORS),$(INSTALL_DATA) ./src/node_exporter/collectors/$(c).uc $(1)$(COLLECTORS_DIR)/;)
	$(INSTALL_DIR) $(1)/usr/libexec/$(PKG_NAME)
	$(INSTALL_DATA) ./files/usr/libexec/$(PKG_NAME)/handler.uc $(1)/usr/libexec/$(PKG_NAME)/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/$(PKG_NAME) $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/$(PKG_NAME) $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/$(PKG_NAME) $(1)/etc/init.d/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

# $(1): the collector's module name, $(2): its name (the package suffix),
# $(3): what it collects, $(4): the packages its needs and commands call for.
# A collector runs on the exporter's API, so it pins the exporter's release.
define Collector
  define Package/$(PKG_NAME)-$(2)
    $$(call Package/$(PKG_NAME)/Default)
    TITLE+= ($(3))
    DEPENDS:=+$(PKG_NAME) $(4)
    EXTRA_DEPENDS:=$(PKG_NAME) (=$(PKG_VERSION)-r$(PKG_RELEASE))
  endef

  define Package/$(PKG_NAME)-$(2)/install
	$$(INSTALL_DIR) $$(1)$(COLLECTORS_DIR)
	$$(INSTALL_DATA) ./src/node_exporter/collectors/$(1).uc $$(1)$(COLLECTORS_DIR)/
  endef

  $$(eval $$(call BuildPackage,$(PKG_NAME)-$(2)))
endef

$(eval $(call Collector,openwrt,openwrt,OpenWrt release and board,))
