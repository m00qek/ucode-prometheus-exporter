ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# Every feed package the exporter, its collector packages and the LuCI app depend on
# (devenv/scripts/package-info.sh), so the container installs the built packages with
# no network; uhttpd-mod-ubus and luci-mod-status for LuCI itself, and the themes.
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
    mkdir -p /var/lock /var/run && \
    apk update && \
    { apk add $FEED_DEPENDS uhttpd uhttpd-mod-ubus luci-mod-status luci-theme-bootstrap "ucode-docopt=$DOCOPT_VERSION" || \
      { echo "pinned: ucode-docopt $DOCOPT_VERSION; the feed has:" >&2; apk search -a -x ucode-docopt >&2; exit 1; }; }
