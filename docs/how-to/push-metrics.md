# How to Push Metrics from the Router

Where nothing can reach the router to scrape it (behind NAT, on a link that comes and goes), the router can send its metrics instead: cron runs `prometheus-exporter scrape` and posts the scrape to a Prometheus Pushgateway, or to VictoriaMetrics' import endpoint.

## Prerequisites

- The exporter installed, with the collectors you want: see [How to install the exporter](install.md). The service itself need not run; `service prometheus-exporter disable` if nothing scrapes it.
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

It posts only a whole scrape: one the command refuses (a collector named that is not installed, say) exits 1 and posts nothing.

For a Pushgateway, post to its grouping key instead:

```sh
URL='http://pushgateway.lan:9091/metrics/job/openwrt/instance/router'
```

To push some collectors only, name them: `prometheus-exporter scrape cpu meminfo netdev`.

## 2. Run it from cron

```sh
chmod +x /usr/bin/push-metrics
echo '* * * * * /usr/bin/push-metrics' >>/etc/crontabs/root
service cron restart
```

Once a minute: each run takes at most the main section's `scrape_timeout`, 10 seconds by default, whatever a collector does.

## 3. Check it

```sh
/usr/bin/push-metrics && echo pushed
logread -e prometheus-exporter
```

What a collector that failed logged is in the log, and in the scrape itself: `node_scrape_collector_success 0`.

---

## What differs from a scrape of `/metrics`

- **The same collectors, the same rules.** The command runs them as the service does, each in a process of its own, stopped at its budget, at most its `max_samples`, in the service's jail where ujail can run (see [The prometheus-exporter command](../reference/command.md#scrape)).
- **No ledger.** Each run is a process of its own: nothing is quarantined from one run to the next, and the collectors run in the order of their names. A collector that keeps failing costs every run its budget: [disable it](choose-collectors.md#disable-a-collector).
- **No `exporter` counters.** `ucode_prometheus_exporter_*_total` count the service's scrapes, which a push does not make.
- **Timestamps.** The Pushgateway refuses a sample with a timestamp, which a textfile `*.prom` file may have: leave those out of a push to it.
- **`up` and `scrape_duration_seconds`** are Prometheus's of a scrape it made: a pushed series has neither. Alert on the series going stale instead.
