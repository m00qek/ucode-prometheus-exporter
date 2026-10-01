# How to Set a Collector's Options

Some collectors take options of their own: wifi's `stations`, dhcp_leases' `leases`, vmstat's `fields`, textfile's `directory`, unbound's `socket`. [Collectors](../reference/collectors.md) lists each collector's options with their defaults; `service prometheus-exporter check` prints each with its help and value.

## Set an option

A collector's options are in its section of `/etc/config/prometheus-exporter`, named after its module: the collector's name with `_` for `-`.

```sh
uci set prometheus-exporter.wifi=collector
uci set prometheus-exporter.wifi.stations=0
uci commit prometheus-exporter
service prometheus-exporter reload
```

The section's type must be `collector`. Without a section, or without the option in it, the collector takes its default.

## Check the value

```sh
service prometheus-exporter check
```

A value the collector does not take is a `FAIL` line, as `collector wifi, section 'wifi': CONFIG_INVALID (stations: expected a boolean, got "maybe")`, and the collector fails in every scrape until it is fixed. `check` exits 1 then.

## Examples

Leave out wifi's per-station metrics, which grow with the clients:

```sh
uci set prometheus-exporter.wifi=collector
uci set prometheus-exporter.wifi.stations=0
```

Have dhcp_leases write a series per lease, with its address, MAC and hostname:

```sh
uci set prometheus-exporter.dhcp_leases=collector
uci set prometheus-exporter.dhcp_leases.leases=1
```

Export more of `/proc/vmstat`, by a regular expression of its field names:

```sh
uci set prometheus-exporter.vmstat=collector
uci set prometheus-exporter.vmstat.fields='^(oom_kill|pgpg|pswp|pg.*fault|nr_free_pages).*'
```

Each is followed by `uci commit prometheus-exporter` and `service prometheus-exporter reload`.

## In LuCI

On **Services → Prometheus exporter**, Collectors tab, the collector's **Edit** button opens its options. **Save** stages them; **Save & Apply** applies them. See [How to use the LuCI app](luci.md).

---

For textfile's directory and unbound's socket, which also change what the jail mounts, see [How to publish metrics from scripts](textfile.md) and [How to monitor Unbound](unbound.md).
