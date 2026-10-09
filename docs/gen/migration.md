# Migrate from prometheus-node-exporter-lua/-ucode

What this exporter has for each package and each metric family of the packages feed's exporters, and how to carry queries, recording rules and the configuration over. The tables are written by `make docs-gen` from the feed exporters' own sources, {{source}} (`make feed-inventory` reads them), and from what this exporter's collectors write, as [Metrics](metrics.md) lists it; the generator refuses a family of theirs it has no row for. The steps are in [How to move from the feed's exporters](../how-to/migrate-from-feed.md); why the names changed, in [Renamed metrics](../metrics.md) and [About metric names](../explanation/metric-names.md).

## Summary {#summary}

Each family of each exporter, by what it is here: the **same** name and labels; **renamed**; **relabeled**, the same name with other labels, or with other values of them (`cpu="0"` for `cpu="cpu0"`); **missing**, written by nothing here. A family of a collector whose name is computed (meminfo's `node_memory_<Field>_bytes`) counts once.

{{summary}}

There is no option to write the old names: see [A transition](#a-transition) for a fleet that runs both for a while.

## Packages {#packages}

Each package of the feed's exporters, and this exporter's package of the collectors it installs. A package of the same name is this exporter's prefix, `ucode-prometheus-exporter`, and the same suffix: `prometheus-node-exporter-lua-nat_traffic` is `ucode-prometheus-exporter-nat_traffic`. The base packages install the same collectors, and more.

{{packages}}

Besides, with no package of the feed's to mirror:

- **`ucode-prometheus-exporter-cli`**, the `prometheus-exporter` command: a scrape on standard output, the checks of the configuration and of a collector module. The feed's exporters had theirs in the base package (`/usr/bin/prometheus-node-exporter-lua` and `-ucode`, a scrape on standard output); here the service needs none of it, and `service prometheus-exporter check` is the base package's. Install it for cron jobs that push a scrape: see [How to push metrics](../how-to/push-metrics.md).
- **The groups**, `ucode-prometheus-exporter-network`, `-wireless`, `-hardware` and `-full`, which install several collectors: see [How to choose collectors](../how-to/choose-collectors.md).
- **`luci-app-prometheus-exporter`**, the LuCI app, and **`ucode-prometheus-exporter-devkit`**, what a collector of another package is written and tested with.
- The collectors the feed had none of: {{extra}}.

A query that selects collectors still does: `collect[]=` as the Lua exporter has it, and `collect=` as the ucode one does. A collector is named as here (`nft-counters`, `ltq-dsl`), or by its module (`nft_counters`); `wifi_stations` is refused, `wifi` writes the stations.

## Metric families {#families}

By the feed's collector. **Lua** and **ucode** are the labels each exporter writes the family with, — where it does not write it; **Here**, the family or families that take its place, with the labels this exporter writes them with, as the captures show them (a label written with an option only is among them). A type that changed is in the notes.

{{families}}

## PromQL {#promql}

How the queries and recording rules most written on the old names read now. The values are the same unless the notes above say otherwise.

**Wi-Fi.** The `wifi_` families are node_exporter's `node_wifi_`, labeled `radio`, the `wifi-device` (the Lua exporter's `device`), and `device`, the interface (the Lua exporter's and the ucode one's `ifname`); a station is `mac_address` (was `mac`). The network's SSID and BSSID are on `node_wifi_network_info` alone:

```promql
# was: wifi_network_signal_dbm{ssid="home"}
node_wifi_network_signal_dbm * on (radio, device) group_left (ssid) node_wifi_network_info{ssid="home"}

# was: sum by (ifname) (wifi_stations)    (Lua's wifi_stations)
sum by (device) (node_wifi_stations)

# was: wifi_network_quality > 50          (a percentage)
node_wifi_network_quality_ratio > 0.5

# was: rate(wifi_station_receive_bytes_total{mac="..."}[5m])
rate(node_wifi_station_receive_bytes_total{mac_address="..."}[5m])
```

**hostapd stations.** The network's labels are on `hostapd_station_info`, one series per station:

```promql
# was: hostapd_station_signal_dbm{ssid="home"}
hostapd_station_signal_dbm * on (vif, station) group_left (ssid) hostapd_station_info{ssid="home"}
```

**NAT traffic.** A series per host on this side of the router, where there was one per pair of addresses:

```promql
# was: sum by (src) (node_nat_traffic)
node_nat_traffic_bytes

# was: topk(10, node_nat_traffic)         (pairs)
topk(10, node_nat_traffic_bytes)          # hosts; the pairs need the option peers
```

**CPU.** `cpu` is the CPU's number, and guest time is apart:

```promql
# was: sum by (cpu) (rate(node_cpu_seconds_total{mode!="idle",cpu="cpu0"}[5m]))
sum by (cpu) (rate(node_cpu_seconds_total{mode!="idle",cpu="0"}[5m]))
```

**Gauges that ended in `_total`.** `node_procs_running`, `node_procs_blocked`, `dawn_ap_stations`; and the counters that did not, `nft_counter_packets_total`, `nft_counter_bytes_total`. A `rate()` of one of the old gauges was a mistake, and is one still.

**Units.** A family whose unit changed is a renamed family: the Lua exporter's `wifi_network_bitrate` in kbit/s is `node_wifi_network_transmit_bits_per_second`, `* 1000`; ModemManager's and bmx7's percentages are ratios, `/ 100`. A recording rule keeps an old dashboard working until it is changed:

```yaml
groups:
  - name: feed-exporter-names
    rules:
      - record: wifi_network_bitrate
        expr: label_replace(node_wifi_network_transmit_bits_per_second / 1000, "ifname", "$1", "device", "(.*)")
      - record: wifi_network_quality
        expr: label_replace(node_wifi_network_quality_ratio * 100, "ifname", "$1", "device", "(.*)")
      - record: node_nat_traffic
        expr: label_replace(node_nat_traffic_bytes, "src", "$1", "host", "(.*)")
```

**unbound.** Each counter is per thread, labeled `thread`, as letsencrypt/unbound_exporter writes them: `sum without (thread) (unbound_queries_total)` is the Lua exporter's `unbound_num_queries_total`.

**Is the collector there?** `node_scrape_collector_success == 0` still finds a collector that failed; a collector whose service or hardware is not there succeeds here, with `node_scrape_collector_observing 0`, where the Lua exporter failed it. See [About nothing to observe](../explanation/nothing-to-observe.md).

## A transition {#a-transition}

A fleet that moves router by router has both names for a while. Where only the name changed, and the labels and the value are the same, Prometheus can rename the old exporter's families at ingestion, so that dashboards and alerts written on the new names see every router: this `metric_relabel_configs`, in the scrape job of the routers still on a feed exporter, is every such family of the tables above.

{{relabel}}

The other changes (a unit, a label, a family split in two) need the queries changed, or recording rules as above. Nothing here writes the old names: the exporter has no compatibility mode.

## The configuration {#configuration}

When the package is installed, its uci-defaults script takes over what `/etc/config/prometheus-node-exporter-ucode` or, without it, `/etc/config/prometheus-node-exporter-lua` sets, into `/etc/config/prometheus-exporter`, once, and logs what it did (see [Log messages](log-messages.md#installation)). It does so only while `/etc/config/prometheus-exporter` is as the package ships it, and leaves the old file as it was. apk keeps a feed exporter's config when it is removed only if it was changed, so what there is to take over is what someone set.

| Old setting | Taken over? |
| :--- | :--- |
| `listen_interface`, `listen_port`, `http_keepalive`, `cert`, `key`, `omit_zero_values` of the main section | Yes, each that this exporter takes the value of; a value it would refuse is left at its default, and logged. A port that is the old exporter's default (9101 of the ucode one, 9100 of the Lua one) is 9100. |
| The ucode exporter's `config collector` sections (wifi's `stations`) | Yes, each named section, option for option, as it is: an option this exporter does not have is kept and ignored; a value it refuses is kept too, and the configuration is then invalid, so the service does not start until it is changed: run `service prometheus-exporter check` after the install. |
| Both old configs | The ucode exporter's alone. |
| Which collectors were installed | No: install the packages of [Packages](#packages). |
| Whether the old service was enabled | No: the exporter is enabled when it is installed. |
| The Lua exporter's textfile directory | Nothing to take over: textfile reads `/var/prometheus` by default, as the Lua exporter did. |
| WireGuard peer descriptions | No: the old exporters labeled peers with their description always; here only with wireguard's option `peer_names`. |

## See also

- [How to move from the feed's exporters](../how-to/migrate-from-feed.md): the steps, and a checklist.
- [Renamed metrics](../metrics.md): why each name changed.
- [Metrics](metrics.md): every family as the collectors write it now.
