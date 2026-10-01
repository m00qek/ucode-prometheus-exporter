# How to Choose Collectors

What a scrape holds is decided three ways: which collector packages are installed, which collectors are enabled, and what each scrape asks for.

## Install collectors

Install a collector's package, or a group of them:

```sh
apk add ucode-prometheus-exporter-wireguard
apk add ucode-prometheus-exporter-network
```

The service reloads with the new collector. [Collectors](../reference/collectors.md) lists each collector, its package, its groups and what it depends on.

## Disable a collector

To stop serving a collector that is installed, base collectors included, set `enabled` to 0 in its section. The section is named after the collector's module: the name with `_` for `-`, as `ltq_dsl` for `ltq-dsl`.

```sh
uci set prometheus-exporter.softnet=collector
uci set prometheus-exporter.softnet.enabled=0
uci commit prometheus-exporter
service prometheus-exporter reload
```

A disabled collector is not run, the jail mounts nothing for it, and a scrape that names it in `collect[]` is refused with a 400. To serve it again, set `enabled` back to 1, or delete its section if nothing else is set there:

```sh
uci delete prometheus-exporter.softnet
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, the switch of its row on the Collectors tab does the same: see [How to use the LuCI app](luci.md).

## Remove a collector

Remove its package: see [How to remove the exporter](uninstall.md#remove-a-collector).

## Choose per scrape

To have one scrape job take some collectors only, give Prometheus the query parameters:

```yaml
scrape_configs:
  - job_name: openwrt-wifi
    params:
      collect[]: [ wifi, hostapd_stations ]
    static_configs:
      - targets: [ 'router.lan:9100' ]
```

`exclude[]` leaves collectors out instead. A name that is not installed, or a disabled one in `collect[]`, makes the scrape fail with a 400. See [HTTP endpoint](../reference/http.md#query-string).

## Check

```sh
service prometheus-exporter status
service prometheus-exporter check
```

`status` counts the collectors served; `check` lists each, enabled or not.
