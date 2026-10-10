ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

ARG OPENWRT_VERSION
# utest and the command line's parser, a dependency of the command line's
# package (ucode-prometheus-exporter-cli), come from their author's feed, pinned to a version and release: apk installs that
# one or fails, so a newer one in the feed changes nothing here until the pin
# is moved. The luci and pkgcheck images pin ucode-docopt to the same.
ARG UTEST_VERSION=1.5.1-r1
ARG DOCOPT_VERSION=1.0.2-r1
ARG UTEST_FEED=https://m00qek.github.io/packages.ucode.dev

# ucode-mod-nl80211 and ucode-mod-socket are optional on a router, but installed
# here so lint can load the named imports deps.uc takes from them; ucode-mod-zlib,
# ucode-mod-digest and ucode-mod-uloop are the base package's (gzip, the crypt
# of basic auth, the processes collectors run in), and ucode-docopt the
# command line's package's. quickjs parses the LuCI app's views; python3-light
# and python3-unittest run the comment stripper of the package build and its
# tests (devenv/scripts/strip-check.sh).
RUN mkdir -p /var/lock /etc/apk/keys /etc/apk/repositories.d && \
    feed="$UTEST_FEED/$(echo "$OPENWRT_VERSION" | cut -d. -f1,2)" && \
    wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem" && \
    echo "$feed" > /etc/apk/repositories.d/ucode-dev.list && \
    apk update && \
    { apk add --no-cache ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci ucode-mod-rtnl ucode-mod-log ucode-mod-nl80211 \
        ucode-mod-socket ucode-mod-zlib ucode-mod-digest ucode-mod-uloop inotifywait quickjs python3-light python3-unittest \
        "ucode-docopt=$DOCOPT_VERSION" "ucode-utest=$UTEST_VERSION" || \
      { echo "pinned: ucode-utest $UTEST_VERSION, ucode-docopt $DOCOPT_VERSION; the feed has:" >&2; \
        apk search -a -x ucode-utest ucode-docopt >&2; exit 1; }; }

WORKDIR /exporter
