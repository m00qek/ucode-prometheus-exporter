# How to Choose Collectors

Three things decide what a scrape holds:

- which collector packages are installed
- which collectors are enabled
- what each scrape asks for

## Install collectors

Install a collector's package, or a group of them:

```sh
apk add ucode-prometheus-exporter-wireguard
apk add ucode-prometheus-exporter-network
```

The service reloads with the new collector. [Collectors](../reference/collectors.md) lists each collector, its package, its groups and what it depends on.

Some collectors are in no group, so only their own package installs them:

- the collectors for particular hardware or services
- `interrupts`, which node_exporter turns off by default because it writes many series, one per interrupt and CPU
- `pressure`, which needs a kernel with `CONFIG_PSI`, which OpenWrt's kernels leave off

Installing the package turns the collector on:

```sh
apk add ucode-prometheus-exporter-interrupts
```

`pressure` has nothing to observe without `/proc/pressure`. Install it only on a kernel built with `CONFIG_PSI`, and not booted with `psi=0`:

```sh
ls /proc/pressure
apk add ucode-prometheus-exporter-pressure
```

## Disable a collector

To stop serving an installed collector, including a base collector, set `enabled` to 0 in its section. The section is named after the collector's module: the collector's name with `_` for `-`, such as `ltq_dsl` for `ltq-dsl`.

```sh
uci set prometheus-exporter.softnet=collector
uci set prometheus-exporter.softnet.enabled=0
uci commit prometheus-exporter
service prometheus-exporter reload
```

The exporter does not run a disabled collector, and the jail mounts nothing for it. A scrape that names it in `collect[]` gets a 400. To serve it again, set `enabled` back to 1, or delete its section if nothing else is set there:

```sh
uci delete prometheus-exporter.softnet
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, the switch in the collector's row on the Collectors tab does the same: see [How to use the LuCI app](luci.md).

## Remove a collector

Remove its package: see [How to remove the exporter](uninstall.md#remove-a-collector).

## Choose per scrape

To make one scrape job take only some collectors, give Prometheus the query parameters:

```yaml
scrape_configs:
  - job_name: openwrt-wifi
    params:
      collect[]: [ wifi, hostapd_stations ]
    static_configs:
      - targets: [ 'router.lan:9100' ]
```

`exclude[]` leaves collectors out instead. The scrape fails with a 400 if it names a collector that is not installed, or names a disabled one in `collect[]`. See [HTTP endpoint](../reference/http.md#query-string).

## Check

```sh
service prometheus-exporter status
service prometheus-exporter check
```

`status` counts the collectors served. `check` lists each collector, enabled or not.
