# How to Install the Exporter

Add the feed the exporter is published in, install the base package, then the collectors you want, one by one or in groups. The service starts on its own, on loopback, port 9100.

## Prerequisites

- A device on OpenWrt 25.12, with a shell on it (ssh), that can reach the internet.
- Neither `prometheus-node-exporter-ucode` nor `prometheus-node-exporter-lua` is installed. If one is, see [How to move from the feed's exporters](migrate-from-feed.md) instead.

---

## 1. Add the feed

The exporter's packages are in the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed, and so is `ucode-docopt`, which the base package depends on and OpenWrt's own feeds do not have. Its other dependencies, `uhttpd`, `ucode` modules and `rpcd-mod-ucode`, come from the release's own feeds. Add the feed and its signing key:

```sh
feed=https://m00qek.github.io/packages.ucode.dev/25.12
wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem"
echo "$feed" > /etc/apk/repositories.d/ucode-dev.list
apk update
```

apk then checks every package of the feed against that key, as it checks OpenWrt's against the release's.

## 2. Choose the packages

- `ucode-prometheus-exporter`, the base package: the service and the collectors every device can use.
- A collector's package, `ucode-prometheus-exporter-<name>`, for each other collector you want: `-wifi`, `-dnsmasq`, `-wireguard`.
- Or a group: `-network`, `-wireless`, `-hardware`, or `-full` for all three and the services every router has.
- `luci-app-prometheus-exporter`, for its pages in LuCI.

[Collectors](../reference/collectors.md) lists every collector, its package and its groups.

## 3. Install them

From the feed:

```sh
apk update
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full luci-app-prometheus-exporter
```

Or from `.apk` files, which `make package` builds into `bin/` (see [Make targets](../reference/make-targets.md#packages-and-the-device)), copied to the device's `/tmp`. `ucode-docopt` still comes from the feed of step 1, unless its own file is among them. Set `version` to the files' version, as their names end:

```sh
version=0.2.0-r1
apk update
apk add --allow-untrusted ucode-docopt /tmp/ucode-prometheus-exporter-$version.apk \
    /tmp/ucode-prometheus-exporter-wifi-$version.apk \
    /tmp/luci-app-prometheus-exporter-$version.apk
```

A group's file brings nothing without its collectors' files: install them together. Every package must be of the same version as the base package.

## 4. Check that it serves

```sh
service prometheus-exporter status
wget -qO- http://127.0.0.1:9100/metrics | head
```

`status` says where it listens and how many collectors it serves. For what each collector found, run `service prometheus-exporter check`.

---

## Next

- [How to listen on the LAN](listen-on-lan.md), for a Prometheus elsewhere.
- [How to serve HTTPS with basic auth](https-basic-auth.md).
- [How to choose collectors](choose-collectors.md).
