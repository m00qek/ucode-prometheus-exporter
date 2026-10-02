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

## From 0.1 to 0.2

0.2.0 changes what 0.1 did in these ways:

- **The command line takes subcommands.** `prometheus-exporter [COLLECTOR...]` is `prometheus-exporter scrape [COLLECTOR...]`, and `prometheus-exporter -l` is `prometheus-exporter collector list`. A script or cron job that runs the command needs the new form: see [The prometheus-exporter command](../reference/command.md).
- **wifi_stations is gone.** It wrote the very families wifi's option `stations` writes, so each station was exported twice. Remove `ucode-prometheus-exporter-wifi_stations` before the upgrade (`apk del ucode-prometheus-exporter-wifi_stations`), and install `ucode-prometheus-exporter-wifi` if it is not there: its `stations` is on by default.
- **A collector that breaks the collector contract fails alone**: it is stopped at its budget, at its `max_samples`, or when it writes another collector's family. See [Collector contract](../reference/collector-contract.md).

## Check the result

```sh
wget -qO- http://127.0.0.1:9100/metrics | grep build_info
service prometheus-exporter check
```

`ucode_prometheus_exporter_build_info{version="..."}` is the new version. The upgrade restarts a running service; `/etc/config/prometheus-exporter` stays as you had it. If you changed it, apk may leave the new version's file beside it, as `/etc/config/prometheus-exporter.apk-new`: compare the two, and remove it once you have taken what you want.
