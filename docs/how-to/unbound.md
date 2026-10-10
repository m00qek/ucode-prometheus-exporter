# How to Monitor Unbound

The unbound collector reads Unbound's statistics from its control socket, a Unix socket. OpenWrt's unbound package makes none: you turn it on, at the path the collector looks for.

## Prerequisites

- Unbound runs on the device (`unbound-daemon`), enabled.
- `ucode-prometheus-exporter-unbound` is installed. It brings `ucode-mod-socket`.

---

## 1. Give Unbound a control socket

Add to `/etc/unbound/unbound_ext.conf`:

```
remote-control:
	control-enable: yes
	control-interface: /var/lib/unbound/unbound.ctl
```

and restart Unbound:

```sh
service unbound restart
```

`/var/lib/unbound` is the directory the package makes for Unbound alone; Unbound makes the socket there when it starts.

## 2. Check it

```sh
ls -l /var/lib/unbound/unbound.ctl
prometheus-exporter scrape unbound | grep unbound_queries_total
```

The service mounts the socket's directory in its jail. At boot Unbound starts after the exporter: the directory is mounted a few seconds after Unbound makes it, and the first scrapes until then fail. `check` warns of it meanwhile:

```
warn jail: unbound: /var/lib/unbound is not there; the service mounts it once it is
```

---

## Extended statistics

Unbound counts more with `extended-statistics: yes`: the queries by type, class, opcode, header flag and transport, the answers by rcode and DNSSEC result, the caches' entries and memory, the modules' memory, and a histogram of the recursion times. OpenWrt's package writes it from the UCI option `extended_stats`:

```sh
uci set unbound.ub_main.extended_stats=1
uci commit unbound
service unbound restart
```

The collector writes them as [letsencrypt/unbound_exporter](https://github.com/letsencrypt/unbound_exporter) names them, `unbound_query_types_total{type}`, `unbound_answer_rcodes_total{rcode}`, `unbound_response_time_seconds` and the rest, once the reply has them; see [Metrics](../reference/metrics.md#unbound). Unbound leaves out a type, class or opcode no query has had yet, so their series come as the queries do. Keeping the counts costs Unbound some time per query, which is why the package leaves them off.

The collector leaves out what unbound_exporter does not export: the memory of the stream and HTTP buffers (`mem.streamwait`, `mem.http.*`) and the caches' lock collisions (`*.max_collisions`). It also leaves out every DNSCrypt statistic of an Unbound built with DNSCrypt, `mem.cache.dnscrypt_*` among them, which unbound_exporter would write as two more caches.

Unbound leaves out a query type, class, opcode or rcode no query had (`stat_inhibit_zero`): those series appear as the queries do.

## Use another socket

If Unbound's socket is elsewhere, tell the collector:

```sh
uci set prometheus-exporter.unbound=collector
uci set prometheus-exporter.unbound.socket=/var/lib/unbound/control.sock
uci commit prometheus-exporter
service prometheus-exporter reload
```

The jail mounts the socket's directory, never the socket. That directory must be Unbound's own: one every service shares, such as `/run` or `/var/run`, is refused, and the collector cannot reach the socket there.

The jail then also holds what else is in that directory: in `/var/lib/unbound`, Unbound's generated config and `root.key`, and the TLS keys of `unbound-control` if its setup made them, all read-only.

## If it fails

| `check` or the log says | Cause |
| :--- | :--- |
| `unbound has nothing to observe: unbound is disabled` | Unbound's init script is disabled. Nothing is wrong. |
| `SOCKET_FAILED (/var/lib/unbound/unbound.ctl: ... No such file or directory)` | No socket: step 1 is missing, or Unbound has not restarted. |
| `SOCKET_FAILED (...: no reply for 1000 ms)` | Unbound did not answer in a second. |
