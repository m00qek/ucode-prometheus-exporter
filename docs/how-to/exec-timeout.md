# How to Give Programs More Time

Some collectors run programs: `ethtool`, `nft`, `tc`, `chronyc`, `mmcli`, `ubnt-manager`. By default, a collector's programs get 5 seconds in all per scrape. If a program is still running after that, the exporter kills it, and the collector fails with `COMMAND_TIMEOUT`.

Give the programs more time when a slow device, or a slow radio over ssh, needs it. Give them less to keep a scrape short.

## Find the collector that runs out of time

```sh
logread -e prometheus-exporter | grep COMMAND_TIMEOUT
```

```
daemon.warn prometheus-exporter[1]: collector 'ubnt-manager': COMMAND_TIMEOUT (ubnt-manager: still running after 5 s, killed)
```

`service prometheus-exporter check` shows each collector's timeout and where it comes from:

```
  ubnt-manager (Ubiquiti airOS radios): section 'ubnt_manager', enabled
      timeout  5s # the main section's exec_timeout
```

## Give one collector more time

Set `timeout`, from 1 to 30 seconds, in the collector's section. The section is named after its module (`ubnt_manager` for `ubnt-manager`):

```sh
uci set prometheus-exporter.ubnt_manager=collector
uci set prometheus-exporter.ubnt_manager.timeout=10
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, the collector's Edit dialog has the same field.

## Change the default for every collector

Set `exec_timeout`, from 1 to 30 seconds, in the main section. It applies to every collector whose section sets no `timeout`:

```sh
uci set prometheus-exporter.main.exec_timeout=3
uci commit prometheus-exporter
service prometheus-exporter reload
```

In LuCI, it is **Program timeout** on the **Limits** tab.

## Keep within Prometheus's timeout

The collectors run one after the other, so a scrape can take as long as all their programs' timeouts added up, and more. Prometheus gives a scrape `scrape_timeout`, 10 seconds by default, and drops the whole scrape when it runs out. If you raise a collector's timeout close to that, also raise `scrape_timeout` for that job, or scrape that collector in a job of its own:

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

Then leave it out of the main job with `exclude[]: [ ubnt-manager ]`.

---

[Collector interface](../reference/collector-interface.md#programs) has the rules for the timeouts, and [UCI configuration](../reference/uci-config.md) the options.
