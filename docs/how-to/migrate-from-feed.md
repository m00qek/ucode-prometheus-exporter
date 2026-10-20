# How to Move from the Feed's Exporters

This exporter replaces the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`. It conflicts with both, takes over their settings when you install it, and writes different metric names. [Migrate from prometheus-node-exporter-lua/-ucode](../reference/migration.md) lists every package and family of theirs, and this exporter's equivalent of each.

## Checklist

1. Note the collector packages installed: `apk info | grep prometheus-node-exporter`. Each has a package here: [Packages](../reference/migration.md#packages).
2. Find the queries, alerts, recording rules and dashboards that use the old names. [Metric families](../reference/migration.md#families) says what each name is now, and [PromQL](../reference/migration.md#promql) how the common queries read.
3. If your fleet moves router by router, add the [transition's relabeling](../reference/migration.md#a-transition) to the job of the routers still on a feed exporter.
4. Remove the old exporter and install this one: steps 1 and 2 below.
5. Check what the install took over, and run `service prometheus-exporter check`: step 3. If a collector section from the ucode exporter has a value this exporter refuses, the service does not start.
6. Install the collector packages of step 1, or a group: `apk add ucode-prometheus-exporter-full`.
7. Point Prometheus at the new port if it changed, and update the queries: step 4.
8. Load the bundled alerts and dashboards, if you want them: [How to monitor a router with the bundled dashboards and alerts](dashboards-and-alerts.md).

## Prerequisites

- One of the feed's exporters is installed, with its collector packages.
- The device has the exporter's feed: see [How to install the exporter](install.md#1-add-the-feed).

---

## 1. Remove the old exporter

apk does not install this exporter beside either feed exporter, or the other way round, and says why:

```
ERROR: unable to select packages:
  prometheus-node-exporter-ucode-2024.02.07-r2:
    breaks: ucode-prometheus-exporter-0.2.0-r1[!prometheus-node-exporter-ucode>=0]
```

Remove the old exporter and its collector packages first:

```sh
apk del -r prometheus-node-exporter-ucode
```

or `prometheus-node-exporter-lua`. If you changed the old config file, apk keeps it. The next step reads it.

## 2. Install this exporter

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full
```

When the package is installed, its uci-defaults script copies the old config's settings into `/etc/config/prometheus-exporter`, once:

- From the main section: `listen_interface`, `listen_port`, `http_keepalive`, `cert`, `key` and `omit_zero_values`.
- From the ucode exporter: each named `config collector` section, with each option the collector takes (wifi's `stations`). It skips a collector this exporter does not have, and the log names it.
- When both old configs are there, it takes the ucode exporter's.

It does this only while `/etc/config/prometheus-exporter` is as the package ships it. The script writes a valid configuration:

- A port left at the old exporter's default (the ucode one's 9101) becomes 9100. A port you chose is kept.
- A value this exporter would refuse is left at its default, and the script logs it.
- An option a collector does not have is left out, and the script logs it.

The script checks a collector section's options as the service checks them, against the installed collector. But the script runs while the base package installs, before the packages installed with it. So it checks a collector that is not installed yet against two things: what the feed's ucode exporter had for it (wifi's `stations`), and the options every collector has (`enabled`, `budget`, `max_samples`).

The old config file stays as it was. [The configuration](../reference/migration.md#configuration) lists what is not taken over.

## 3. Check what it took

```sh
logread -e prometheus-exporter | grep -e imported -e 'left at' -e 'left out' -e 'nothing imported'
uci show prometheus-exporter
service prometheus-exporter check
```

The log names every option the script took, every value it left at the default, and every option it left out, and why. See [Log messages](../reference/log-messages.md#installation).

## 4. Update Prometheus

- **The port.** If the old exporter was the ucode one on 9101, scrape 9100, or set `listen_port` back to 9101.
- **The metric names.** They differ from the old exporters'. Most follow node_exporter. [Migrate from prometheus-node-exporter-lua/-ucode](../reference/migration.md#families) lists every family, and [Renamed metrics](../metrics.md) says why each changed. Update the queries, alerts and recording rules that use an old name. Dashboards made for node_exporter work unchanged.
- **The collectors.** A query that selected collectors with `collect[]=` still works, and so does `collect=`, the ucode exporter's spelling.
- **The Lua exporter's wifi_stations.** This exporter has no such collector. Install `ucode-prometheus-exporter-wifi`: its option `stations`, on by default, writes the station metrics. The exporter refuses `collect[]=wifi_stations`, so select `wifi`.
- **WireGuard peer names.** The old exporters always labelled peers with their description. This one does so only after `uci set prometheus-exporter.wireguard=collector; uci set prometheus-exporter.wireguard.peer_names=1; uci commit prometheus-exporter; service prometheus-exporter reload`. See [Security model](../explanation/security.md) for why it is off.

---

## If nothing was imported

`/etc/config/prometheus-exporter is not as the package ships it: nothing imported from /etc/config/<old>` means the new config was already changed. Set the options by hand: see [UCI configuration](../reference/uci-config.md).
