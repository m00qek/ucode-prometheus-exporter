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
#
# ucode-docopt, the command line's parser, is not in the release's feeds: it
# comes from its author's feed, which the devenv's image takes utest from,
# pinned to the version and release that image pins it to
# (devenv/services/openwrt/Dockerfile). The pinned name comes after
# FEED_DEPENDS, which names it bare: apk keeps the last.
ARG OPENWRT_VERSION
ARG UCODE_FEED=https://m00qek.github.io/packages.ucode.dev
ARG DOCOPT_VERSION=1.0.2-r1
ARG FEED_DEPENDS
RUN mkdir -p /var/lock /var/run /etc/apk/keys /etc/apk/repositories.d && \
    feed="$UCODE_FEED/$(echo "$OPENWRT_VERSION" | cut -d. -f1,2)" && \
    wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem" && \
    echo "$feed" > /etc/apk/repositories.d/ucode-dev.list && \
    mkdir -p /var/lock /var/run /opt/feed && \
    apk update && \
    { apk add $FEED_DEPENDS ucode-mod-uloop "ucode-docopt=$DOCOPT_VERSION" || \
      { echo "pinned: ucode-docopt $DOCOPT_VERSION; the feed has:" >&2; apk search -a -x ucode-docopt >&2; exit 1; }; } && \
    apk fetch -o /opt/feed prometheus-node-exporter-ucode && \
    { [ ! -x /etc/init.d/unbound ] || /etc/init.d/unbound disable; } && \
    { [ ! -x /etc/init.d/chronyd ] || /etc/init.d/chronyd disable; }
