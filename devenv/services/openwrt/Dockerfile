ARG OPENWRT_ARCH=x86_64
ARG OPENWRT_VERSION=25.12.5
FROM ghcr.io/openwrt/rootfs:${OPENWRT_ARCH}-${OPENWRT_VERSION}

ARG OPENWRT_VERSION
ARG UTEST_VERSION=1.5.1
ARG UTEST_FEED=https://m00qek.github.io/packages.ucode.dev

# ucode-mod-nl80211 and ucode-mod-socket are optional on a router, but installed
# here so lint can load the named imports deps.uc takes from them.
RUN mkdir -p /var/lock /etc/apk/keys /etc/apk/repositories.d && \
    feed="$UTEST_FEED/$(echo "$OPENWRT_VERSION" | cut -d. -f1,2)" && \
    wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem" && \
    echo "$feed" > /etc/apk/repositories.d/ucode-dev.list && \
    apk update && \
    apk add --no-cache ucode ucode-mod-fs ucode-mod-ubus ucode-mod-uci ucode-mod-rtnl ucode-mod-nl80211 \
      ucode-mod-socket ucode-utest inotifywait && \
    apk list -I 2>/dev/null | grep -q "^ucode-utest-$UTEST_VERSION-" || \
      { echo "expected ucode-utest $UTEST_VERSION" >&2; exit 1; }

WORKDIR /exporter
