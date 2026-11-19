ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

# Every feed package the exporter, its collector packages and the LuCI app depend on
# (devenv/scripts/package-info.sh), so the container installs the built packages with
# no network; uhttpd-mod-ubus and luci-mod-status for LuCI itself, and the themes.
#
# ucode-docopt, the parser of the command line's package, which the lab
# installs, is not in the release's feeds: it comes from its author's feed,
# which the devenv's image takes utest from, pinned to the version and release
# that image pins it to (devenv/services/openwrt/Dockerfile).
ARG OPENWRT_VERSION
ARG UCODE_FEED=https://m00qek.github.io/packages.ucode.dev
ARG DOCOPT_VERSION=1.0.2-r1
ARG FEED_DEPENDS
# What the image takes from its author's feed installed, the feed is left out
# of apk's repositories: it publishes the exporter's packages, of which one of
# the version the tree builds would stand beside the built one.
#
# uhttpd and its modules are upgraded together: the rootfs image holds an
# older uhttpd than the index's uhttpd-mod-ucode, which apk add installs, and
# that module does not open a handler in the older uhttpd.
#
# ucode as the release's package index has it (UCODE_ENGINE=index), what a
# device gets, or as the rootfs image holds it (rootfs): the two read newlines
# in regular expressions apart (devenv/services/openwrt/Dockerfile).
ARG UCODE_ENGINE=index
RUN mkdir -p /var/lock /var/run /etc/apk/keys /etc/apk/repositories.d && \
    feed="$UCODE_FEED/$(echo "$OPENWRT_VERSION" | cut -d. -f1,2)" && \
    wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem" && \
    echo "$feed" > /etc/apk/repositories.d/ucode-dev.list && \
    mkdir -p /var/lock /var/run && \
    apk update && \
    { apk add $FEED_DEPENDS uhttpd uhttpd-mod-ubus luci-mod-status luci-theme-bootstrap "ucode-docopt=$DOCOPT_VERSION" || \
      { echo "pinned: ucode-docopt $DOCOPT_VERSION; the feed has:" >&2; apk search -a -x ucode-docopt >&2; exit 1; }; } && \
    apk upgrade --no-cache uhttpd 'uhttpd-mod-*' && \
    { [ "$UCODE_ENGINE" = rootfs ] || apk upgrade --no-cache 'libucode*' ucode 'ucode-mod-*'; } && \
    apk list -I 'libucode*' 2>/dev/null && \
    rm /etc/apk/repositories.d/ucode-dev.list
