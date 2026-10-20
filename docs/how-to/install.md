# How to Install the Exporter

Add the exporter's feed, install the base package, then install the collectors you want, one by one or in groups. The service starts on its own, on loopback, port 9100.

## Prerequisites

- A device on OpenWrt 25.12, with a shell on it (ssh), that can reach the internet.
- Neither `prometheus-node-exporter-ucode` nor `prometheus-node-exporter-lua` is installed. If one is, see [How to move from the feed's exporters](migrate-from-feed.md) instead.

---

## 1. Add the feed

This step needs a shell on the device: LuCI's **System → Software** page cannot add a signing key.

The exporter's packages are in the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed. So is `ucode-docopt`, which the command line's package depends on and OpenWrt's own feeds lack. The base package's dependencies (`uhttpd`, `ucode` modules and `rpcd-mod-ucode`) come from the release's own feeds. Add the feed and its signing key:

```sh
feed=https://m00qek.github.io/packages.ucode.dev/25.12
wget -qO /etc/apk/keys/packages.ucode.dev.pem "$feed/feed.pub.pem"
echo "$feed" > /etc/apk/repositories.d/ucode-dev.list
apk update
```

apk then checks every package of the feed against that key, as it checks OpenWrt's packages against the release's key.

## 2. Choose the packages

- `ucode-prometheus-exporter`, the base package: the service and the collectors every device can use.
- A collector's package, `ucode-prometheus-exporter-<name>`, for each other collector you want: `-wifi`, `-dnsmasq`, `-wireguard`.
- Or a group: `-network`, `-wireless`, `-hardware`, or `-full` for all three and the services every router has.
- `luci-app-prometheus-exporter`, for its pages in LuCI.
- `ucode-prometheus-exporter-cli`, for the [`prometheus-exporter` command](../reference/command.md). It prints a scrape on standard output, hashes a password, and checks a collector before you install it. The service and LuCI do not need it. On a router short of flash, leave it out (see [How to run the exporter on a small device](small-device.md)).

[Collectors](../reference/collectors.md) lists every collector, its package and its groups.

## 3. Install them

From the feed:

=== "Browser (LuCI)"

    1. Open **System → Software** and press **Update lists…**.
    2. Type `prometheus-exporter` in **Filter**.
    3. On the **Available** tab, press **Install…** on the row of `ucode-prometheus-exporter`, then **Install** in the dialog.
    4. Do the same for each other package you chose: `ucode-prometheus-exporter-full`, `luci-app-prometheus-exporter`, `ucode-prometheus-exporter-cli`.
    5. Reload the browser page, so LuCI shows the app's pages.

=== "Terminal (SSH)"

    ```sh
    apk update
    apk add ucode-prometheus-exporter ucode-prometheus-exporter-full luci-app-prometheus-exporter ucode-prometheus-exporter-cli
    ```

Or from `.apk` files, over SSH. `make package` builds them into `bin/` (see [Make targets](../reference/make-targets.md#packages-and-the-device)). Copy them to the device's `/tmp`, and set `version` to the files' version, as their names end:

```sh
version=0.3.0-r1
apk update
apk add --allow-untrusted /tmp/ucode-prometheus-exporter-$version.apk \
    /tmp/ucode-prometheus-exporter-wifi-$version.apk \
    /tmp/luci-app-prometheus-exporter-$version.apk
```

The command line's file, `ucode-prometheus-exporter-cli-$version.apk`, also needs `ucode-docopt`. apk takes it from the feed of step 1, unless you add its file too.

A group's file brings nothing without its collectors' files, so install them together. Every package must have the same version as the base package.

## 4. Check that it serves

=== "Browser (LuCI)"

    Open **Status → Prometheus exporter**. Under **Service**, **State** says **Running**, and **Metrics** gives the address it serves, `http://127.0.0.1:9100/metrics` (reachable from the router only). Under **Collectors**, **Test run** says what each collector found.

=== "Terminal (SSH)"

    ```sh
    service prometheus-exporter status
    wget -qO- http://127.0.0.1:9100/metrics | head
    ```

    `status` says where the exporter listens and how many collectors it serves. To see what each collector found, run `service prometheus-exporter check`.

---

## Next

- [How to listen on the LAN](listen-on-lan.md), for a Prometheus elsewhere.
- [How to serve HTTPS with basic auth](https-basic-auth.md).
- [How to choose collectors](choose-collectors.md).
