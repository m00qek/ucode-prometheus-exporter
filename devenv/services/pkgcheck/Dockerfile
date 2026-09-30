ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# Every package the built packages depend on (devenv/scripts/package-info.sh
# feed-depends), so the check installs them all with no network; one missing
# from the feed fails here. uloop is for the stand-in of procd's `system`
# object (devenv/scripts/system-board.uc).
ARG FEED_DEPENDS
RUN mkdir -p /var/lock /var/run && \
    apk update && \
    apk add $FEED_DEPENDS ucode-mod-uloop
