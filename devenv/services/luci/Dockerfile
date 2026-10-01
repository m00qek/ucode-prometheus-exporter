ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# Every feed package the exporter, its collector packages and the LuCI app depend on
# (devenv/scripts/package-info.sh), so the container installs the built packages with
# no network; uhttpd-mod-ubus and luci-mod-status for LuCI itself, and the themes.
ARG FEED_DEPENDS
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add $FEED_DEPENDS uhttpd uhttpd-mod-ubus luci-mod-status luci-theme-bootstrap
