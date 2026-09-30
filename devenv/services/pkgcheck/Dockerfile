ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# The base package's dependencies, so the check installs it with no network; and
# uloop, for the stand-in of procd's `system` object (devenv/scripts/system-board.uc).
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add uhttpd uhttpd-mod-ucode ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci ucode-mod-uloop
