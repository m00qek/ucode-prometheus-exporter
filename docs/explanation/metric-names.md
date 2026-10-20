# About Metric Names

The metric names are not those of the feed's exporters. They are the Prometheus node_exporter's where it has the metric, and elsewhere follow the Prometheus naming conventions. This page is about why, and about the one name the exporter writes of itself.

---

## node_exporter's names first

Where node_exporter has a metric, this exporter uses its name, type, labels and help text: `node_cpu_seconds_total{cpu="0",mode}`, not the `cpu="cpu0"` the feed's exporters wrote; `node_wifi_*` with `device` and `mac_address`, not `wifi_*` with `ifname` and `mac`. The point is the ecosystem around node_exporter: dashboards such as Grafana's "Node Exporter Full", recording rules and alerts written for Linux hosts all work on a router without a single edit. A router is a Linux host, and its CPU, memory, disks and network devices should look like one.

## The conventions elsewhere

Most of what a router has, node_exporter does not: netifd's interfaces, DHCP leases, hostapd's stations, DSL lines, PoE ports. Those follow the [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/):

- base units in the name: `_seconds`, `_bytes`, `_hertz`, `_bits_per_second`, `_celsius`, `_ratio`, and `_dbm` or `_db` for radio levels;
- `_total` on counters only, and every counter ends in `_total`;
- a metric of labels only is `<name>_info`, with the value 1;
- a boolean is a gauge of 0 or 1; an enumeration, one series per state;
- snake_case names, and no unit on a unitless value.

The feed's exporters broke these here and there: gauges with `_total`, kilobits, percentages, milliseconds, labels that changed with the state and so started a new series. Each such name is fixed, and each fix is listed in [Renamed metrics](../metrics.md).

A service keeps its own prefix, `dnsmasq_`, `wireguard_`, `unbound_`, `adguard_`, and OpenWrt's own metrics are `node_openwrt_*`. Where a widely used standalone exporter exists for a service and its names follow the conventions, they are taken too: letsencrypt's unbound_exporter, prometheus_wireguard_exporter, chrony_exporter. Someone who monitors Unbound on a server already has queries for those names.

## A window's totals are gauges

A counter only goes up, except across a restart, and `rate()` and `increase()` rely on that: they take a value lower than the one before as a reset, and count what follows from zero. Some services give totals that are not counters. AdGuard Home's statistics are the queries of its last 24 hours, by default. As the window moves, an hour falls out of them, so a total falls too. Written as a counter, each fall would read as a reset, and `increase()` would count the window's whole total again, a silently wrong number that looks right.

So such a total is a gauge, named for what it is, `adguard_stats_dns_queries`, without `_total`, beside the length of its window, `adguard_stats_window_seconds`. A counter could be made of it only by keeping the last scrape's totals and adding the differences. The exporter keeps nothing from one scrape to the next that a restart would lose. See [How to monitor AdGuard Home](../how-to/adguard-home.md#query-the-statistics-window) for the queries that use them as they are.

## Modern names only

There is no option to get the old names back. A compatibility mode would mean writing every metric twice, or picking names per device, and every query, dashboard and alert would have to know which. The cost of renaming is paid once, when moving from a feed exporter; carried as an option, it would be paid by every later change, every collector and every test, for as long as the option lived.

## The exporter's own

Every scrape ends with `ucode_prometheus_exporter_build_info{version}`, whatever `collect[]` selects, as node_exporter writes `node_exporter_build_info`. Its value is always 1; its `version` is the package's, `0.1.0-r1`, or `dev` from a source tree. It answers "which version runs on that router?" from Prometheus alone, and a version change shows as a new series at the moment of an upgrade. It is named after the exporter, not `node_`, because it describes the exporter, not the node.

Beside node_exporter's `node_scrape_collector_success` and `node_scrape_collector_duration_seconds`, the exporter adds `node_scrape_collector_observing`: see [About nothing to observe](nothing-to-observe.md).

## See also

- [Metrics](../reference/metrics.md): every family each collector writes.
- [Renamed metrics](../metrics.md): every name that changed, and why.
- [How to move from the feed's exporters](../how-to/migrate-from-feed.md).
