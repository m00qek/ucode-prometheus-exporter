# How to Choose Collectors

Three things decide what a scrape holds:

- which collector packages are installed
- which collectors are enabled
- what each scrape asks for

## Install collectors

Install a collector's package, or a group of them:

=== "Browser (LuCI)"

    1. Open **System → Software** and press **Update lists…**.
    2. Type the package's name in **Filter**, such as `ucode-prometheus-exporter-wireguard` or the group `ucode-prometheus-exporter-network`.
    3. On the **Available** tab, press **Install…** on its row, then **Install** in the dialog.

=== "Terminal (SSH)"

    ```sh
    apk add ucode-prometheus-exporter-wireguard
    apk add ucode-prometheus-exporter-network
    ```

The service reloads with the new collector. [Collectors](../reference/collectors.md) lists each collector, its package, its groups and what it depends on.

Some collectors are in no group, so only their own package installs them:

- the collectors for particular hardware or services
- `interrupts`, which node_exporter turns off by default because it writes many series, one per interrupt and CPU
- `pressure`, which needs a kernel with `CONFIG_PSI`, which OpenWrt's kernels leave off

Installing the package turns the collector on, as above: `ucode-prometheus-exporter-interrupts`, for example.

`pressure` has nothing to observe without `/proc/pressure`. Install it only on a kernel built with `CONFIG_PSI`, and not booted with `psi=0`. Check for the directory first, over SSH:

```sh
ls /proc/pressure
apk add ucode-prometheus-exporter-pressure
```

## Disable a collector

You can stop serving any installed collector, including a base collector.

=== "Browser (LuCI)"

    1. Open **Services → Prometheus exporter**, tab **Collectors**. It lists the collectors by title: softnet is **Network softirq statistics**.
    2. Untick the collector in the **Enabled** column.
    3. Press **Save & Apply**.

    See [How to use the LuCI app](luci.md).

=== "Terminal (SSH)"

    Set `enabled` to 0 in the collector's section. The section is named after the collector's module: the collector's name with `_` for `-`, such as `ltq_dsl` for `ltq-dsl`.

    ```sh
    uci set prometheus-exporter.softnet=collector
    uci set prometheus-exporter.softnet.enabled=0
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```

The exporter does not run a disabled collector, and the jail mounts nothing for it. A scrape that names it in `collect[]` gets a 400. To serve it again:

=== "Browser (LuCI)"

    Tick the collector again in the **Enabled** column, and press **Save & Apply**.

=== "Terminal (SSH)"

    Set `enabled` back to 1, or delete the collector's section if nothing else is set there:

    ```sh
    uci delete prometheus-exporter.softnet
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```

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

=== "Browser (LuCI)"

    The **Collectors** tab of **Services → Prometheus exporter** says how many collectors are enabled, as `15 of 16 collectors enabled`. **Status → Prometheus exporter** lists each collector, with **Not run: switched off** for a disabled one.

=== "Terminal (SSH)"

    ```sh
    service prometheus-exporter status
    service prometheus-exporter check
    ```

    `status` counts the collectors served. `check` lists each collector, enabled or not.
