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

## A collector works in `check` and fails under procd

`check`, the ubus object's `status`, LuCI's status page and the `prometheus-exporter` command run outside the jail, as root. Prometheus's scrapes run in it. A collector that only fails there lacks something the jail does not give it.

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
| A timeout | The firewall drops it, or a collector's programs take too long: see [How to give programs more time](exec-timeout.md). |
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
