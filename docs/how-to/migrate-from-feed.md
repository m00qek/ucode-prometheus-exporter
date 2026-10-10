# How to Move from the Feed's Exporters

This exporter replaces the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`. It conflicts with both, takes over their settings when it is installed, and writes other metric names. Every package and family of theirs, and this exporter's for each, is in [Migrate from prometheus-node-exporter-lua/-ucode](../reference/migration.md).

## Checklist

1. Note the collector packages installed: `apk info | grep prometheus-node-exporter`. Each has a package here: [Packages](../reference/migration.md#packages).
2. Find the queries, alerts, recording rules and dashboards that use the old names: [Metric families](../reference/migration.md#families) says what each is now, and [PromQL](../reference/migration.md#promql) how the common ones read.
3. For a fleet that moves router by router, add the [transition's relabeling](../reference/migration.md#a-transition) to the job of the routers still on a feed exporter.
4. Remove the old exporter and install this one: steps 1 and 2 below.
5. Check what the install took over, and run `service prometheus-exporter check`: step 3. A collector section of the ucode exporter's with a value this exporter refuses keeps the service from starting.
6. Install the collector packages of step 1, or a group: `apk add ucode-prometheus-exporter-full`.
7. Point Prometheus at the new port if it changed, and update the queries: step 4.
8. Load the bundled alerts and dashboards, if you want them: [How to monitor a router with the bundled dashboards and alerts](dashboards-and-alerts.md).

## Prerequisites

- One of the feed's exporters is installed, with its collector packages.
- The device has the exporter's feed: see [How to install the exporter](install.md#1-add-the-feed).

---

## 1. Remove the old exporter

apk installs neither feed exporter beside this one, nor this one beside either, and says why:

```
ERROR: unable to select packages:
  prometheus-node-exporter-ucode-2024.02.07-r2:
    breaks: ucode-prometheus-exporter-0.2.0-r1[!prometheus-node-exporter-ucode>=0]
```

Remove the old exporter and its collector packages first:

```sh
apk del -r prometheus-node-exporter-ucode
```

or `prometheus-node-exporter-lua`. apk keeps the old config file if you changed it: that is what the next step reads.

## 2. Install this exporter

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full
```

When the package is installed, its uci-defaults script takes over what the old config sets into `/etc/config/prometheus-exporter`, once:

- From the main section: `listen_interface`, `listen_port`, `http_keepalive`, `cert`, `key` and `omit_zero_values`.
- From the ucode exporter, each named `config collector` section, each option the collector takes (wifi's `stations`), but for a collector this exporter has not, which the log names.
- When both old configs are there, the ucode exporter's.

It does so only while `/etc/config/prometheus-exporter` is as the package ships it. A port left at the old exporter's default (the ucode one's 9101) becomes 9100; a port you chose is kept. A value this exporter would refuse is left at its default, and an option a collector has not is left out, each logged, so what it writes is a valid configuration. A collector section's options are checked as the service checks them, against the collector installed; the script runs as the base package is installed, before the packages installed with it, so a collector not installed yet is checked against what the feed's ucode exporter had of it (wifi's `stations`) and the options every collector has (`enabled`, `budget`, `max_samples`). The old config file stays as it was. What is not taken over is in [The configuration](../reference/migration.md#configuration).

## 3. Check what it took

```sh
logread -e prometheus-exporter | grep -e imported -e 'left at' -e 'left out' -e 'nothing imported'
uci show prometheus-exporter
service prometheus-exporter check
```

The log names every option it took, and every value it left at the default or option it left out, and why. See [Log messages](../reference/log-messages.md#installation).

## 4. Update Prometheus

- **The port.** If the old exporter was the ucode one on 9101, scrape 9100, or set `listen_port` back to 9101.
- **The metric names.** They are not the old exporters': most follow node_exporter, and every family is in [Migrate from prometheus-node-exporter-lua/-ucode](../reference/migration.md#families), why each changed in [Renamed metrics](../metrics.md). Update the queries, alerts and recording rules that use an old name. Dashboards made for node_exporter work as they are.
- **The collectors.** A query that selected collectors with `collect[]=` still does; `collect=`, the ucode exporter's spelling, too.
- **The Lua exporter's wifi_stations.** This exporter has no such collector: install `ucode-prometheus-exporter-wifi`, whose option `stations`, on by default, writes the station metrics. A `collect[]=wifi_stations` is refused; select `wifi`.
- **WireGuard peer names.** The old exporters labelled peers with their description always; this one only with `uci set prometheus-exporter.wireguard=collector; uci set prometheus-exporter.wireguard.peer_names=1; uci commit prometheus-exporter; service prometheus-exporter reload`. See [Security model](../explanation/security.md) for why it is off.

---

## If nothing was imported

`/etc/config/prometheus-exporter is not as the package ships it: nothing imported from /etc/config/<old>` means the new config had been changed already. Set the options by hand: [UCI configuration](../reference/uci-config.md).
