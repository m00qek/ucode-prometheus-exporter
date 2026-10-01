# How to Move from the Feed's Exporters

This exporter replaces the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`. It conflicts with both, takes over their settings when it is installed, and writes other metric names.

## Prerequisites

- One of the feed's exporters is installed, with its collector packages.
- The new packages are at hand: see [How to install the exporter](install.md).

---

## 1. Remove the old exporter

apk installs neither feed exporter beside this one, nor this one beside either, and says why:

```
ERROR: unable to select packages:
  prometheus-node-exporter-ucode-2024.02.07-r2:
    breaks: ucode-prometheus-exporter-0.1.0-r1[!prometheus-node-exporter-ucode>=0]
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
- From the ucode exporter, each named `config collector` section, option for option (wifi's `stations`).
- When both old configs are there, the ucode exporter's.

It does so only while `/etc/config/prometheus-exporter` is as the package ships it. A port left at the old exporter's default (the ucode one's 9101) becomes 9100; a port you chose is kept. A value this exporter would refuse is left at its default. The old config file stays as it was.

## 3. Check what it took

```sh
logread -e prometheus-exporter | grep -e imported -e 'left at the default' -e 'nothing imported'
uci show prometheus-exporter
```

The log names every option it took, and every value it left at the default and why. See [Log messages](../reference/log-messages.md#installation).

## 4. Update Prometheus

- **The port.** If the old exporter was the ucode one on 9101, scrape 9100, or set `listen_port` back to 9101.
- **The metric names.** They are not the old exporters': most follow node_exporter, and every change is in [Renamed metrics](../metrics.md). Update the queries, alerts and recording rules that use an old name. Dashboards made for node_exporter work as they are.
- **The collectors.** A query that selected collectors with `collect[]=` still does; `collect=`, the ucode exporter's spelling, too.

---

## If nothing was imported

`/etc/config/prometheus-exporter is not as the package ships it: nothing imported from /etc/config/<old>` means the new config had been changed already. Set the options by hand: [UCI configuration](../reference/uci-config.md).
