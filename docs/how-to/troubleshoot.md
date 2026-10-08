# How to Troubleshoot

Start from what is wrong: the service, one collector, or the scrape as Prometheus sees it.

## The service does not run

```sh
service prometheus-exporter status
logread -e prometheus-exporter
```

| `status` or the log says | Do |
| :--- | :--- |
| `disabled (option enabled in /etc/config/prometheus-exporter)` | `uci set prometheus-exporter.main.enabled=1`, commit, `service prometheus-exporter start`. |
| `invalid configuration, not starting`, after the lines that say why | Fix the option it names: `service prometheus-exporter check` shows the same as `FAIL` lines. See [UCI configuration](../reference/uci-config.md). |
| `deferring start until listen interface <name> becomes ready` | The interface has no address yet. It starts once it has one; check `ifstatus <name>`, or listen elsewhere: [How to listen on the LAN](listen-on-lan.md). |
| `basic auth takes HTTPS only, and <cert> or <key> is missing: not starting` | The TLS files are not there. See [How to serve HTTPS with basic auth](https-basic-auth.md). |
| `cannot make <path>: <error>` | The service could not make a directory: tmpfs is full, or the path is wrong. |

A reload with an invalid configuration keeps the running exporter, and logs `invalid configuration, keeping the running instance`.

## A collector fails

`check` runs a scrape and says, for each collector, whether it succeeded, failed and why, or had nothing to observe and why:

```sh
service prometheus-exporter check
```

```
warn scrape: dnsmasq: UBUS_CALL_FAILED (dnsmasq metrics: Not found)
ok   scrape: wifi has nothing to observe: no wireless radios
```

- **Nothing to observe** is not a failure: the device has no such hardware, kernel feature, or running service. The collector succeeds without samples, and its `node_scrape_collector_observing` is 0. If you do not want it, [disable it](choose-collectors.md#disable-a-collector). Each collector's cases are in [Collectors](../reference/collectors.md#nothing-to-observe).
- **A failure** is a `warn` line with a code. [Error codes](../reference/error-codes.md) says what each means. Under procd, each failing scrape also logs it at `warning`:

    ```sh
    logread -e prometheus-exporter | grep "collector '"
    ```

The same is on LuCI's **Status → Prometheus exporter** page, and in the ubus object's `status`:

```sh
ubus call prometheus-exporter status
```

## A collector is quarantined

A collector whose program was killed at its timeout, that was still running at the end of its budget, whose process ended under it, or that failed three scrapes in a row is left out for a few scrapes, then tried again. Its `node_scrape_collector_success` is 0 and its `ucode_prometheus_exporter_collector_quarantined` is 1. `check` says why, and when the service tries it again:

```
warn service: nat_traffic is quarantined: COLLECTOR_OVERRUN (took 7.84 s, over its budget of 5 s); the service tries it again in 8 scrapes, or at once once restarted
```

1. Fix what tripped it: the `warn scrape:` line of `check` runs it now and says how it fails.
2. If it is slow but you want it, raise its budget: `uci set prometheus-exporter.<module>=collector`, `uci set prometheus-exporter.<module>.budget=15`, commit, `reload_config`. For a program, raise its `timeout`: [How to give programs more time](exec-timeout.md).
3. To try it at once rather than at its trial, `service prometheus-exporter restart`: a restart forgets every quarantine.

LuCI's **Status → Prometheus exporter** shows the same in its **Service's scrapes** column, and names the quarantined collectors in a notice above the tables. How often it happened since the service started is the `exporter` collector's `ucode_prometheus_exporter_quarantines_total{collector}`.

## A collector breaks the contract

The log says `collector '<name>': ` and one of these, and the collector fails alone: every other is served as before.

| Error | What happened | Do |
| :--- | :--- | :--- |
| `COLLECTOR_CANCELLED` | It was still running at the end of its budget, and was stopped with its process: a loop that never ends, or a read that never returns (a FIFO, a socket). | If it is only slow, raise its `budget`; otherwise it is a bug of the collector. |
| `COLLECTOR_KILLED` | Its process ended under it: past the memory limit, a crash, `exit()`; or its scrape process died while it ran, `collector '<name>' was running when a scrape process died`. | Raise `memory_limit` if it is only large; otherwise it is a bug. |
| `SAMPLE_LIMIT` | It wrote more than its `max_samples`: the detail says how many, and in which family. | If its output is that large on this device, raise its `max_samples`. |
| `EXPOSITION_INVALID` | It wrote what Prometheus would refuse the whole scrape for: a label value or HELP text that is not valid UTF-8 (a Latin-1 SSID or hostname), or two label names that are one once sanitized. The detail names the family and the label. | A bug of the collector, which should make the value valid or leave it out. |
| `FAMILY_CONFLICT` | It wrote a family another collector writes, or one the exporter keeps for itself: the detail names it. | Disable one of the two, or fix the collector's names. |
| `hung at load` (at `err`) | Its module's top level did not return in 5 s: it is left out until the service restarts. | A bug of the module. |

`prometheus-exporter collector check <module file>` runs a module as the service would and says which rule it breaks: see [Collector contract](../reference/collector-contract.md).

## Collectors are left out at the deadline

The log says `scrape deadline: <n> collectors not served in its <seconds> s: ...`, and `check` says `the scrape deadline left <name> out`: a scrape ran out of the time the scraper gives it. Collectors run fastest first, so the ones left out are the slowest.

- Leave the slow collector out of this job, `params: { 'exclude[]': [ nat_traffic ] }`, and scrape it in a job of its own with a longer `scrape_timeout` (and a `budget` to match).
- Or raise the job's `scrape_timeout`: Prometheus sends it with each scrape.
- A scraper that does not send `X-Prometheus-Scrape-Timeout-Seconds` gets the main section's `scrape_timeout`, 10 seconds.
- `ucode_prometheus_exporter_deadline_skips_total{collector}` counts them since the service started.

See [About deadlines and circuit breakers](../explanation/deadlines-and-breakers.md).

## A collector works in `check` and fails under procd

`check`, the ubus object's `status`, LuCI's status page and `prometheus-exporter scrape` run the collectors in the service's own jail, as Prometheus's scrapes do: they find what Prometheus gets. Where ujail cannot run they run outside the jail, as root, and `check` says `scrape, outside the jail`; a collector that works there and fails under procd lacks something the jail does not give it.

1. See what the jail gives it:

    ```sh
    service prometheus-exporter check | grep '^warn jail'
    ubus call service list '{"name":"prometheus-exporter"}'
    ```

    `check` warns of a path or program it cannot mount; procd's list shows what it mounted.

2. A path that was not there when the service started is mounted once it is: `check` says `<path> is not there; the service mounts it once it is`, and the `watch` instance reloads the service when it appears. To mount it at once, `service prometheus-exporter restart`.
3. A program that is not installed is a `jail: <collector>: command <name> is not on ...` warning: install its package.

What the jail holds is in [The jail](../reference/jail.md).

## Prometheus cannot scrape it

| Prometheus says | Do |
| :--- | :--- |
| `connection refused` | The exporter does not listen where Prometheus asks. `service prometheus-exporter status` says where it listens; by default, loopback only. See [How to listen on the LAN](listen-on-lan.md). |
| A timeout | The firewall drops it, or the scrape is slow: the exporter answers within the timeout the scraper sends, but not on the first scrape after a restart, before it knows how long each collector takes. A timeout scrape after scrape is a scraper that sends none: set `scrape_timeout` to its timeout. |
| `400 Bad Request` | The scrape's `collect[]` names a collector that is not installed, or is disabled. The body says which. |
| `401 Unauthorized` | The user or password is wrong. |
| `server returned HTTP status 403 Forbidden` | Basic auth is on and the request came over HTTP: use `scheme: https`. |
| `500 Internal Server Error` | Basic auth's file is broken: `service prometheus-exporter restart` writes it afresh. |

## The metrics are not what you expect

- A name changed from the feed's exporters: see [Renamed metrics](../metrics.md).
- A label is missing: a collector leaves out a label it has no value for.
- Counters that are 0 are missing: `option omit_zero_values '1'` leaves them out.
- What the scrape says of itself: `node_scrape_collector_success` 0 for a failure, `node_scrape_collector_observing` 0 for nothing to observe, `node_scrape_collector_duration_seconds` for the time each took.

```promql
node_scrape_collector_success == 0
```

alerts on a failing collector, and leaves alone one with nothing to observe.
