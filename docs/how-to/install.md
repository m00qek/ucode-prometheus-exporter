# How to Install the Exporter

Install the base package, then the collectors you want, one by one or in groups. The service starts on its own, on loopback, port 9100.

## Prerequisites

- A device on OpenWrt 25.12, with a shell on it (ssh).
- The packages: from a package feed your device uses, or as `.apk` files, which `make package` builds into `bin/` (see [Make targets](../reference/make-targets.md#packages-and-the-device)).
- The device can reach its release's own feeds: the packages depend on `uhttpd`, `ucode` modules and `rpcd-mod-ucode`, which come from there.
- Neither `prometheus-node-exporter-ucode` nor `prometheus-node-exporter-lua` is installed. If one is, see [How to move from the feed's exporters](migrate-from-feed.md) instead.

---

## 1. Choose the packages

- `ucode-prometheus-exporter`, the base package: the service and the collectors every device can use.
- A collector's package, `ucode-prometheus-exporter-<name>`, for each other collector you want: `-wifi`, `-dnsmasq`, `-wireguard`.
- Or a group: `-network`, `-wireless`, `-hardware`, or `-full` for all three and the services every router has.
- `luci-app-prometheus-exporter`, for its pages in LuCI.

[Collectors](../reference/collectors.md) lists every collector, its package and its groups.

## 2. Install them

From a feed:

```sh
apk update
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full luci-app-prometheus-exporter
```

From `.apk` files, copied to the device's `/tmp`:

```sh
apk update
apk add --allow-untrusted /tmp/ucode-prometheus-exporter-0.1.0-r1.apk \
    /tmp/ucode-prometheus-exporter-wifi-0.1.0-r1.apk \
    /tmp/luci-app-prometheus-exporter-0.1.0-r1.apk
```

A group's file brings nothing without its collectors' files: install them together. Every package must be of the same version as the base package.

## 3. Check that it serves

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
