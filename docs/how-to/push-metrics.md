# How to Push Metrics from the Router

Sometimes nothing can reach the router to scrape it: it is behind NAT, or on a link that comes and goes. The router can then send its metrics instead. Cron runs `prometheus-exporter scrape` and posts the scrape to a Prometheus Pushgateway, or to VictoriaMetrics' import endpoint.

## Prerequisites

- The exporter installed, with the collectors you want, and its command line, `ucode-prometheus-exporter-cli`: see [How to install the exporter](install.md). The service itself need not run. If nothing scrapes it, run `service prometheus-exporter disable`.
- `curl`: `apk add curl`.
- A Pushgateway or VictoriaMetrics the router can reach.

---

## 1. Write the script

```sh
#!/bin/sh
# /usr/bin/push-metrics: a scrape of the router, posted to $URL.
URL='http://vm.lan:8428/api/v1/import/prometheus?extra_label=instance=router'
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT
prometheus-exporter scrape >"$out" || exit 1
curl -fsS --max-time 10 --data-binary @"$out" "$URL"
```

The script posts only a whole scrape. If the command refuses the scrape (for example, because it names a collector that is not installed), it exits 1 and the script posts nothing.

For a Pushgateway, post to its grouping key instead:

```sh
URL='http://pushgateway.lan:9091/metrics/job/openwrt/instance/router'
```

To push only some collectors, name them: `prometheus-exporter scrape cpu meminfo netdev`.

## 2. Run it from cron

```sh
chmod +x /usr/bin/push-metrics
echo '* * * * * /usr/bin/push-metrics' >>/etc/crontabs/root
service cron restart
```

This runs the script once a minute. Each run takes at most the main section's `scrape_timeout`, 10 seconds by default, whatever a collector does.

## 3. Check it

```sh
/usr/bin/push-metrics && echo pushed
logread -e prometheus-exporter
```

A collector that failed shows in the log, and in the scrape itself as `node_scrape_collector_success 0`.

---

## What differs from a scrape of `/metrics`

- **The same collectors, the same rules.** The command runs the collectors as the service does: each in its own process, stopped at its budget, limited to its `max_samples`, and in the service's jail where ujail can run (see [The prometheus-exporter command](../reference/command.md#scrape)).
- **No ledger.** Each run is a separate process, so nothing stays quarantined from one run to the next, and the collectors run in the order of their names. A collector that keeps failing costs every run its budget: [disable it](choose-collectors.md#disable-a-collector).
- **No `exporter` counters.** `ucode_prometheus_exporter_*_total` count the service's scrapes, and a push makes none.
- **Timestamps.** The Pushgateway refuses a sample with a timestamp, and a textfile `*.prom` file may have one. Leave such files out of a push to the Pushgateway.
- **`up` and `scrape_duration_seconds`** come from Prometheus, for a scrape it made, so a pushed series has neither. Alert on the series going stale instead.
