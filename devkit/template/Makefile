# A collector of another package than the exporter's, for the OpenWrt SDK:
# copy this directory to the SDK's package/ (or a feed of yours), rename
# `example` (PKG_NAME, the module and its test), and build it with
#   make package/ucode-prometheus-exporter-example/compile

include $(TOPDIR)/rules.mk

PKG_NAME:=ucode-prometheus-exporter-example
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Your Name <you@example.com>

include $(INCLUDE_DIR)/package.mk

COLLECTORS_DIR:=/usr/share/ucode/prometheus/collectors

# The release of the exporter whose collector API it is written to: 0.3.0
# froze the API for 1.0, and a major version is what may break it.
EXPORTER_MIN?=0.3.0

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Prometheus exporter collector (uptime and swap, an example)
  # The exporter, and what the collector reads WITH (a library, a tool):
  # never what it WATCHES (a daemon, a subsystem), whose absence is nothing
  # to observe. This one reads procfs alone.
  DEPENDS:=+ucode-prometheus-exporter
  EXTRA_DEPENDS:=ucode-prometheus-exporter (>=$(EXPORTER_MIN))
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Seconds since boot, and each swap area, for ucode-prometheus-exporter:
  the devkit's template of a collector in a package of its own.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)$(COLLECTORS_DIR)
	$(INSTALL_DATA) ./src/prometheus/collectors/example.uc $(1)$(COLLECTORS_DIR)/
endef

# On a running system (not in an image build), reload an enabled exporter:
# it restarts with the collector served or gone, its jail mounting what the
# collectors now declare. A failed reload fails no install.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || ! /etc/init.d/prometheus-exporter enabled ||
	/etc/init.d/prometheus-exporter reload || true
endef

Package/$(PKG_NAME)/postrm = $(Package/$(PKG_NAME)/postinst)

$(eval $(call BuildPackage,$(PKG_NAME)))
