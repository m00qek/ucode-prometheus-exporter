# Copyright (C) 2013-2017 OpenWrt.org

include $(TOPDIR)/rules.mk

PKG_NAME:=ucode-prometheus-exporter
# Date versions, as the feed's exporters have.
PKG_VERSION:=2026.09.30
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE NOTICE
PKG_MAINTAINER:=António Mora <m00qek@gmail.com>

include $(INCLUDE_DIR)/package.mk

# The service: its init script, command, config and libexec directory.
SERVICE:=prometheus-exporter
MODULES_DIR:=/usr/share/ucode/prometheus_exporter
COLLECTORS_DIR:=$(MODULES_DIR)/collectors

# Installed with the exporter itself; every other collector is a subpackage.
BASE_COLLECTORS:=conntrack cpu entropy filefd loadavg meminfo netclass netdev openwrt_interfaces selinux softnet time uname vmstat

define Package/$(PKG_NAME)/Default
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Prometheus exporter
  PKGARCH:=all
endef

define Package/$(PKG_NAME)
  $(call Package/$(PKG_NAME)/Default)
  DEPENDS:=+uhttpd +uhttpd-mod-ucode +ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uci +ucode-mod-rtnl
  # The feed's exporters it replaces, which want the same port. CONFLICTS
  # keeps an image from building both in, but apk packages do not carry it:
  # a dependency on !<name> is apk's conflict, refused either way round.
  CONFLICTS:=prometheus-node-exporter-ucode prometheus-node-exporter-lua
  EXTRA_DEPENDS:=!prometheus-node-exporter-ucode (>=0), !prometheus-node-exporter-lua (>=0)
endef

define Package/$(PKG_NAME)/description
  Metrics of OpenWrt for Prometheus, served by uhttpd at /metrics. Written in
  ucode; each optional collector is a subpackage.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/$(SERVICE)
endef

# The exporter's code stays loaded while it runs: after an upgrade, a running
# exporter is restarted. Collector packages reload it themselves.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || [ "$$PKG_UPGRADE" != 1 ] || ! /etc/init.d/$(SERVICE) running ||
	/etc/init.d/$(SERVICE) restart
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)$(MODULES_DIR) $(1)$(COLLECTORS_DIR)
	$(INSTALL_DATA) ./src/prometheus_exporter/*.uc $(1)$(MODULES_DIR)/
	# The version ucode_prometheus_exporter_build_info reports: the package's.
	$(SED) "/^const VERSION = /s/'dev'/'$(PKG_VERSION)-r$(PKG_RELEASE)'/" $(1)$(MODULES_DIR)/version.uc
	grep -q "^const VERSION = '$(PKG_VERSION)-r$(PKG_RELEASE)';" $(1)$(MODULES_DIR)/version.uc
	$(foreach c,$(BASE_COLLECTORS),$(INSTALL_DATA) ./src/prometheus_exporter/collectors/$(c).uc $(1)$(COLLECTORS_DIR)/;)
	$(INSTALL_DIR) $(1)/usr/libexec/$(SERVICE)
	$(INSTALL_DATA) ./files/usr/libexec/$(SERVICE)/handler.uc $(1)/usr/libexec/$(SERVICE)/
	$(INSTALL_BIN) $(foreach f,jail check status import,./files/usr/libexec/$(SERVICE)/$(f).uc) $(1)/usr/libexec/$(SERVICE)/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/$(SERVICE) $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/$(SERVICE) $(1)/etc/config/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/$(SERVICE) $(1)/etc/init.d/
	# Run once, before the service first starts: takes over a feed exporter's settings.
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/$(SERVICE)-import $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

# A collector package's scripts: on a running system (not in an image build),
# reload an enabled exporter, which restarts it with the collector served or
# gone, and its jail mounts what the collectors now declare. A failed reload
# (an invalid config) is logged by the init script and fails no install.
define Collector/reload
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || ! /etc/init.d/$(SERVICE) enabled ||
	/etc/init.d/$(SERVICE) reload || true
endef

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
	$$(INSTALL_DATA) ./src/prometheus_exporter/collectors/$(1).uc $$(1)$(COLLECTORS_DIR)/
  endef

  define Package/$(PKG_NAME)-$(2)/postinst
$$(Collector/reload)
  endef

  define Package/$(PKG_NAME)-$(2)/postrm
$$(Collector/reload)
  endef

  $$(eval $$(call BuildPackage,$(PKG_NAME)-$(2)))
endef

$(eval $(call Collector,bmx7,bmx7,bmx7 mesh node and links,))
$(eval $(call Collector,dawn,dawn,DAWN access points and clients,))
$(eval $(call Collector,dhcp_leases,dhcp_leases,active DHCP leases of dnsmasq and odhcpd,))
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
$(eval $(call Collector,unbound,unbound,Unbound DNS resolver,+ucode-mod-socket))
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
FULL_GROUP:=$(NETWORK_GROUP) $(WIRELESS_GROUP) $(HARDWARE_GROUP) dhcp_leases dnsmasq openwrt textfile uci_dhcp_host wireguard

$(eval $(call Group,network,network statistics,$(NETWORK_GROUP)))
$(eval $(call Group,wireless,Wi-Fi,$(WIRELESS_GROUP)))
$(eval $(call Group,hardware,hardware and filesystems,$(HARDWARE_GROUP)))
$(eval $(call Group,full,a router or access point,$(FULL_GROUP)))

# ---- luci-app-prometheus-exporter --------------------------------------------
# The LuCI pages, and the rpcd plugin they call (prometheus_exporter.luci.rpc). The
# plugin runs the exporter's own modules, so the app pins the exporter's release.
# ucode-mod-uloop: the plugin waits for a status scrape without blocking rpcd.
LUCI_APP:=luci-app-$(SERVICE)

define Package/$(LUCI_APP)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for the Prometheus exporter
  DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-uloop +$(PKG_NAME)
  EXTRA_DEPENDS:=$(PKG_NAME) (=$(PKG_VERSION)-r$(PKG_RELEASE))
  PKGARCH:=all
endef

define Package/$(LUCI_APP)/description
  LuCI pages for the Prometheus exporter: its settings and its collectors'
  options, and whether it runs and how each collector does.
endef

# luci.mk's default postinst, also run on removal: drop LuCI's menu and module
# caches, and reload rpcd for the plugin and the ACL.
define Package/$(LUCI_APP)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
endef

Package/$(LUCI_APP)/postrm = $(Package/$(LUCI_APP)/postinst)

define Package/$(LUCI_APP)/install
	$(INSTALL_DIR) $(1)/www
	$(CP) ./luci/htdocs/* $(1)/www/
	$(CP) ./luci/root/* $(1)/
	$(INSTALL_DIR) $(1)$(MODULES_DIR)/luci
	$(INSTALL_DATA) ./src/prometheus_exporter/luci/*.uc $(1)$(MODULES_DIR)/luci/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/$(SERVICE).uc $(1)/usr/share/rpcd/ucode/
	$(INSTALL_DIR) $(1)/usr/libexec/$(SERVICE)
	$(INSTALL_BIN) ./files/usr/libexec/$(SERVICE)/luci-status.uc $(1)/usr/libexec/$(SERVICE)/
endef

$(eval $(call BuildPackage,$(LUCI_APP)))
