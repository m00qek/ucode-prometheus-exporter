# Copyright (C) 2013-2017 OpenWrt.org

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
BASE_COLLECTORS:=conntrack cpu entropy filefd loadavg meminfo netclass netdev selinux time uname

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

$(eval $(call Collector,bmx7,bmx7,bmx7 mesh node and links,))
$(eval $(call Collector,dawn,dawn,DAWN access points and clients,))
$(eval $(call Collector,dnsmasq,dnsmasq,dnsmasq DNS and DHCP metrics,))
$(eval $(call Collector,ethtool,ethtool,network driver statistics,+ethtool))
$(eval $(call Collector,filesystem,filesystem,filesystem sizes,+luci-base))
$(eval $(call Collector,hostapd_stations,hostapd_stations,hostapd stations,))
$(eval $(call Collector,hostapd_ubus_stations,hostapd_ubus_stations,hostapd station radio measurement capabilities,))
$(eval $(call Collector,hwmon,hwmon,hardware monitor sensors,))
$(eval $(call Collector,ltq_dsl,ltq-dsl,Lantiq DSL line,))
$(eval $(call Collector,modemmanager,modemmanager,ModemManager signal,+modemmanager))
$(eval $(call Collector,mwan3,mwan3,mwan3 interface tracking,+mwan3))
$(eval $(call Collector,nat_traffic,nat_traffic,conntrack bytes per address pair,))
$(eval $(call Collector,netstat,netstat,protocol statistics,))
$(eval $(call Collector,nft_counters,nft-counters,nftables counters,+nftables-json))
$(eval $(call Collector,openwrt,openwrt,OpenWrt release and board,))
$(eval $(call Collector,realtek_poe,realtek-poe,Realtek PoE switch,))
$(eval $(call Collector,snmp6,snmp6,IPv6 statistics,))
$(eval $(call Collector,textfile,textfile,metrics from text files,))
$(eval $(call Collector,thermal,thermal,thermal zone temperatures,))
$(eval $(call Collector,ubnt_manager,ubnt-manager,Ubiquiti airOS radios,+ubnt-manager))
$(eval $(call Collector,uci_dhcp_host,uci_dhcp_host,static DHCP leases,))
$(eval $(call Collector,wifi,wifi,Wi-Fi radios networks and stations,+ucode-mod-nl80211))
$(eval $(call Collector,wifi_stations,wifi_stations,Wi-Fi stations,+ucode-mod-nl80211))
$(eval $(call Collector,wireguard,wireguard,WireGuard interfaces and peers,+rpcd-mod-wireguard))

# $(1): the group's name (the package suffix), $(2): what it is for, $(3): the
# names of its collectors. A group installs no files of its own, only its
# collectors: removing it from a device's world lets apk remove them too.
define Group
  define Package/$(PKG_NAME)-$(1)
    $$(call Package/$(PKG_NAME)/Default)
    TITLE+= ($(2))
    DEPENDS:=+$(PKG_NAME) $(foreach c,$(3),+$(PKG_NAME)-$(c))
    EXTRA_DEPENDS:=$(PKG_NAME) (=$(PKG_VERSION)-r$(PKG_RELEASE))
  endef

  define Package/$(PKG_NAME)-$(1)/description
  The collectors for $(2): $(3).
  endef

  # Empty, but defined: a package without an install step is not built.
  define Package/$(PKG_NAME)-$(1)/install
	true
  endef

  $$(eval $$(call BuildPackage,$(PKG_NAME)-$(1)))
endef

NETWORK_GROUP:=ethtool nat_traffic netstat nft-counters snmp6
# Not wifi_stations, which repeats the station metrics of wifi, nor dawn, which needs DAWN.
WIRELESS_GROUP:=hostapd_stations hostapd_ubus_stations wifi
HARDWARE_GROUP:=filesystem hwmon thermal
# Not the collectors of particular hardware or services: DSL, PoE, bmx7, mwan3, ModemManager, airOS.
FULL_GROUP:=$(NETWORK_GROUP) $(WIRELESS_GROUP) $(HARDWARE_GROUP) dnsmasq openwrt textfile uci_dhcp_host wireguard

$(eval $(call Group,network,network statistics,$(NETWORK_GROUP)))
$(eval $(call Group,wireless,Wi-Fi,$(WIRELESS_GROUP)))
$(eval $(call Group,hardware,hardware and filesystems,$(HARDWARE_GROUP)))
$(eval $(call Group,full,a router or access point,$(FULL_GROUP)))
