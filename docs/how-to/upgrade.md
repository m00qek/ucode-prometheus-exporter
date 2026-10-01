# How to Upgrade the Exporter

Every collector package, group and the LuCI app depends on the base package of the very same version, so they move together.

## Before you upgrade

Read what the new version changes. Before 1.0.0 a minor version may rename metrics or options: see [About versions](../explanation/versions.md). A renamed metric breaks the queries and dashboards that use the old name.

---

## From a feed

```sh
apk update
apk upgrade
```

## From `.apk` files

Copy every package you have installed, in the new version, to the device's `/tmp`, and add them in one command:

```sh
apk add --allow-untrusted /tmp/ucode-prometheus-exporter-*0.2.0-r1.apk /tmp/luci-app-prometheus-exporter-0.2.0-r1.apk
```

Adding the base package alone fails: the installed collectors still want the old version.

## Check the result

```sh
wget -qO- http://127.0.0.1:9100/metrics | grep build_info
service prometheus-exporter check
```

`ucode_prometheus_exporter_build_info{version="..."}` is the new version. The upgrade restarts a running service; `/etc/config/prometheus-exporter` stays as you had it. If you changed it, apk may leave the new version's file beside it, as `/etc/config/prometheus-exporter.apk-new`: compare the two, and remove it once you have taken what you want.
