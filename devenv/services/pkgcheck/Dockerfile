ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# Every package the built packages depend on (devenv/scripts/package-info.sh
# feed-depends), so the check installs them all with no network; one missing
# from the feed fails here. uloop is for the stand-ins of procd's and netifd's
# ubus objects (devenv/scripts/ubus-stand-ins.uc).
#
# The feed's ucode exporter is fetched, not installed, into /opt/feed: the
# checks install it to see apk refuse the two side by side. unbound (in
# FEED_DEPENDS, for e2e) does not start at boot: e2e starts it when it has
# set it up, after the exporter, as at a device's boot. Nor does chronyd,
# which sysntpd's ntpd would fight for the clock, which a privileged
# container shares with its host: e2e starts it, without a network, when it
# checks chrony.
ARG FEED_DEPENDS
RUN mkdir -p /var/lock /var/run /opt/feed && \
    apk update && \
    apk add $FEED_DEPENDS ucode-mod-uloop && \
    apk fetch -o /opt/feed prometheus-node-exporter-ucode && \
    { [ ! -x /etc/init.d/unbound ] || /etc/init.d/unbound disable; } && \
    { [ ! -x /etc/init.d/chronyd ] || /etc/init.d/chronyd disable; }
