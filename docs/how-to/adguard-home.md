# How to Monitor AdGuard Home

The agh collector reads AdGuard Home's HTTP API on the router: `/control/status`, whether it runs and protects, and `/control/stats`, the totals of its statistics window. It reads them without a login, at an address of the router.

## Prerequisites

- AdGuard Home runs on the router (`adguardhome`), enabled, and its setup is done.
- Its web interface has no users: `users: []` in `/etc/adguardhome/adguardhome.yaml`. The collector sends no credentials; see [If it fails](#if-it-fails).
- `ucode-prometheus-exporter-agh` is installed. It brings `ucode-mod-socket`, and not AdGuard Home.

---

## 1. Point the collector at AdGuard Home's web interface

The collector connects to `127.0.0.1`, port `8080`, by default. Find where AdGuard Home listens, `http.address` in its config:

```sh
grep -A12 '^http:' /etc/adguardhome/adguardhome.yaml | grep address
```

```
  address: 0.0.0.0:8080
```

- `0.0.0.0` or `127.0.0.1`, port 8080: nothing to do.
- Another port, as the setup's 3000: set `port`.
- One address of the router, as `192.168.1.1:8080`, which OpenWrt's guide to AdGuard Home has you choose: set `address` to it, since AdGuard Home does not answer on `127.0.0.1` then.

```sh
uci set prometheus-exporter.agh=collector
uci set prometheus-exporter.agh.address=192.168.1.1
uci set prometheus-exporter.agh.port=8080
uci commit prometheus-exporter
service prometheus-exporter reload
```

`address` is an address of the router itself, IPv4 or IPv6: the collector refuses any other, without connecting (see [About the security model](../explanation/security.md#a-jail-built-from-declarations)).

## 2. Check it

```sh
wget -qO- 'http://127.0.0.1:9100/metrics?collect[]=agh' | grep '^adguard_'
```

```
adguard_up 1
adguard_build_info{version="0.107.79"} 1
adguard_running 1
adguard_protection_enabled 1
adguard_start_time_seconds 1792437171.9284565
adguard_stats_window_seconds 86400
adguard_stats_dns_queries 14496
adguard_stats_blocked_filtering 1482
...
```

The families and what each means are in [Metrics](../reference/metrics.md#agh).

---

## Query the statistics window

`/control/stats` gives totals over AdGuard Home's statistics window, the last 24 hours by default (its `statistics.interval`), not counters since it started: as the window moves, the oldest hour drops out and a total can fall. So they are gauges, `adguard_stats_*`, beside the window's length, `adguard_stats_window_seconds`, and not `_total` counters. `rate()` and `increase()` take a fall for a counter reset, and would count the whole total again; use them as gauges:

| For | Query |
| :--- | :--- |
| Queries in the last 24 hours | `adguard_stats_dns_queries` |
| Queries a second, averaged over the window | `adguard_stats_dns_queries / adguard_stats_window_seconds` |
| Share blocked by the filters | `adguard_stats_blocked_filtering / adguard_stats_dns_queries` |
| Blocked by safe browsing and parental control | `adguard_stats_replaced_safebrowsing + adguard_stats_replaced_parental` |
| Mean answer time | `adguard_stats_avg_processing_time_seconds` |
| AdGuard Home down, or not answering | `adguard_up == 0`, or `node_scrape_collector_success{collector="agh"} == 0` |
| Filtering paused | `adguard_protection_enabled == 0` |

A rate over a few minutes is not there to be had: the window's totals move by the hour, as AdGuard Home rolls its hourly units. For counters of every query, read AdGuard Home's query log, or a resolver that counts, as [Unbound](unbound.md) does.

The collector writes nothing of the domains, clients and upstreams AdGuard Home ranks (`top_queried_domains`, `top_clients`, `top_blocked_domains`): they would be a series for each, without bound, and what the people on the network browse.

### From dashboards of other names

A dashboard written for `node_adguard_*` names, as some scripts for the textfile collector wrote them, needs these:

| Was | Is | Change |
| :--- | :--- | :--- |
| `node_adguard_up` | `adguard_up` | The name. |
| `node_adguard_dns_queries_total` | `adguard_stats_dns_queries` | The name; and `rate()` or `increase()` of it, a window's total, becomes the gauge itself, or its ratio to `adguard_stats_window_seconds`. |
| `node_adguard_blocked_filtering_total` | `adguard_stats_blocked_filtering` | As the queries. |
| `node_adguard_avg_processing_seconds` | `adguard_stats_avg_processing_time_seconds` | The name. |

## If it fails

| `check` or the log says | Cause |
| :--- | :--- |
| `agh has nothing to observe: adguardhome is not installed`, or `is disabled` | Nothing answered, and AdGuard Home is not installed, or its init script is disabled. Nothing is wrong. |
| `SOCKET_FAILED (127.0.0.1:8080: connect(): Connection refused)` | AdGuard Home is enabled and does not listen there: it is stopped, or listens on another address or port. Step 1. |
| `SOCKET_FAILED (192.0.2.1:8080: 192.0.2.1 is not an address of this device, ...)` | `address` is not one of the router's. |
| `SOURCE_UNREADABLE (...: AdGuard Home asks for a login (401 Unauthorized), ...)` | AdGuard Home has users. The collector reads only one without: a password it could send would sit where the service's user, and every collector, reads it, and the exporter keeps no secret there. |
| `SOURCE_INVALID (...: not a JSON object)`, `(...: 404 Not Found)` | Something else answers at that address and port, as LuCI's uhttpd on port 80. |
