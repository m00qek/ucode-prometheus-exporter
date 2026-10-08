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
- **A collector's package no longer installs what it watches.** The packages of mwan3, chrony, modemmanager, ubnt-manager and wireguard depended on mwan3, chrony, modemmanager, ubnt-manager and rpcd-mod-wireguard: installing the mwan3 collector installed and started mwan3, which changes the routing, and the chrony one a second NTP daemon. They depend on none of them now; where it is not there, the collector has nothing to observe. An upgrade removes nothing: apk keeps what was installed. If one was installed only for its collector, remove it (`apk del mwan3`, say).
- **A collector imports the collector API alone.** A collector module imports `prometheus_exporter.api`, which exports `Result`, `errors`, `services`, `proc` and `exposition`, and no other module: one that imports `prometheus_exporter.result`, `fs` or any other is left out, logged at `err`. Every collector of the exporter's packages already does. A collector of another package written for 0.1, should one exist, takes the same names from the API: `import { Result, errors, proc } from 'prometheus_exporter.api';`, and `proc.first_line(...)` for `first_line(...)`. Check it with `prometheus-exporter collector check`. See [Collector contract](../reference/collector-contract.md#what-a-collector-may-import).
- **A collector's options need a title.** Each option of `meta.options` declares `title`, the label LuCI's Edit dialog shows it by, short and in sentence case: `device_exclude: { default: '...', title: 'Excluded devices', help: '...' }`. A collector with an option that has none is left out, logged at `err`. Every collector of the exporter's packages has them. See [Collector interface](../reference/collector-interface.md#options).
- **A collector that breaks the collector contract fails alone**: it is stopped at its budget, at its `max_samples`, or when it writes another collector's family. See [Collector contract](../reference/collector-contract.md).

## Check the result

```sh
wget -qO- http://127.0.0.1:9100/metrics | grep build_info
service prometheus-exporter check
```

`ucode_prometheus_exporter_build_info{version="..."}` is the new version. The upgrade restarts a running service; `/etc/config/prometheus-exporter` stays as you had it. If you changed it, apk may leave the new version's file beside it, as `/etc/config/prometheus-exporter.apk-new`: compare the two, and remove it once you have taken what you want.
