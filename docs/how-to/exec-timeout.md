# How to Give Programs More Time

Some collectors run programs: `ethtool`, `nft`, `tc`, `chronyc`, `mmcli`, `ubnt-manager`. Each such collector's programs get 5 seconds in all per scrape, by default; one still running then is killed, and its collector fails with `COMMAND_TIMEOUT`. Give them more when a slow device, or a slow radio over ssh, needs it; less, to keep a scrape short.

## Find the collector that runs out of time

```sh
logread -e prometheus-exporter | grep COMMAND_TIMEOUT
```

```
daemon.warn prometheus-exporter[1]: collector 'ubnt-manager': COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed)
```

`service prometheus-exporter check` shows each collector's seconds and where they come from:

```
  ubnt-manager (Ubiquiti airOS radios): section 'ubnt_manager', enabled
      timeout  5s # the main section's exec_timeout
```

## Give one collector more time

Set `timeout` in its section, named after its module (`ubnt_manager` for `ubnt-manager`), from 1 to 30 seconds:

```sh
uci set prometheus-exporter.ubnt_manager=collector
uci set prometheus-exporter.ubnt_manager.timeout=10
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, the collector's Edit dialog has the same field.

## Change the default for every collector

Set `exec_timeout` in the main section, from 1 to 30 seconds. It applies to every collector whose section sets no `timeout`:

```sh
uci set prometheus-exporter.main.exec_timeout=3
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, it is **Program timeout** on the **Limits** tab.

## Keep within Prometheus's timeout

The collectors run one after the other: a scrape can take as long as the sum of their programs' seconds, and more. Prometheus gives a scrape `scrape_timeout`, 10 seconds by default, and drops the whole scrape when it runs out. If you raise a collector's seconds near it, raise `scrape_timeout` for that job too, or scrape that collector in a job of its own:

```yaml
scrape_configs:
  - job_name: openwrt-radios
    scrape_interval: 60s
    scrape_timeout: 30s
    params:
      collect[]: [ ubnt-manager ]
    static_configs:
      - targets: [ 'router.lan:9100' ]
```

and leave it out of the main job with `exclude[]: [ ubnt-manager ]`.

---

The rules of the seconds are in [Collector interface](../reference/collector-interface.md#programs), and the options in [UCI configuration](../reference/uci-config.md).
