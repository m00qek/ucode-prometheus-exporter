# How to Monitor Unbound

The unbound collector reads Unbound's statistics from its control socket, a Unix socket. OpenWrt's unbound package does not create one, so you turn it on, at the path the collector looks for.

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

Then restart Unbound:

```sh
service unbound restart
```

The package creates `/var/lib/unbound` for Unbound alone. Unbound creates the socket there when it starts.

## 2. Check it

```sh
ls -l /var/lib/unbound/unbound.ctl
prometheus-exporter scrape unbound | grep unbound_queries_total
```

The service mounts the socket's directory in its jail. At boot, Unbound starts after the exporter. The service mounts the directory a few seconds after Unbound creates it, and the scrapes before that fail. Until then, `check` warns:

```
warn jail: unbound: /var/lib/unbound is not there; the service mounts it once it is
```

---

## Extended statistics

With `extended-statistics: yes`, Unbound counts more:

- the queries by type, class, opcode, header flag and transport
- the answers by rcode and DNSSEC result
- the caches' entries and memory, and the modules' memory
- a histogram of the recursion times

OpenWrt's package sets it from the UCI option `extended_stats`:

```sh
uci set unbound.ub_main.extended_stats=1
uci commit unbound
service unbound restart
```

Once the reply has them, the collector writes them with [letsencrypt/unbound_exporter](https://github.com/letsencrypt/unbound_exporter)'s names: `unbound_query_types_total{type}`, `unbound_answer_rcodes_total{rcode}`, `unbound_response_time_seconds` and the rest. See [Metrics](../reference/metrics.md#unbound). Keeping these counts costs Unbound some time per query, which is why the package leaves them off.

Unbound leaves out a query type, class, opcode or rcode that no query has had yet (`stat_inhibit_zero`). Those series appear as the queries arrive.

The collector leaves out what unbound_exporter does not export: the memory of the stream and HTTP buffers (`mem.streamwait`, `mem.http.*`) and the caches' lock collisions (`*.max_collisions`). For an Unbound built with DNSCrypt, it also leaves out every DNSCrypt statistic, including `mem.cache.dnscrypt_*`, which unbound_exporter would write as two more caches.

## Use another socket

If Unbound's socket is elsewhere, tell the collector:

```sh
uci set prometheus-exporter.unbound=collector
uci set prometheus-exporter.unbound.socket=/var/lib/unbound/control.sock
uci commit prometheus-exporter
service prometheus-exporter reload
```

The jail mounts the socket's directory, never the socket itself. That directory must be Unbound's own. The service refuses a directory that every service shares, such as `/run` or `/var/run`, and the collector then cannot reach the socket.

The jail also holds everything else in that directory, read-only. In `/var/lib/unbound`, that is Unbound's generated config and `root.key`, and the TLS keys of `unbound-control` if its setup created them.

## If it fails

| `check` or the log says | Cause |
| :--- | :--- |
| `unbound has nothing to observe: unbound is disabled` | Unbound's init script is disabled. Nothing is wrong. |
| `SOCKET_FAILED (/var/lib/unbound/unbound.ctl: ... No such file or directory)` | No socket: step 1 is missing, or Unbound has not restarted. |
| `SOCKET_FAILED (...: no reply for 1000 ms)` | Unbound did not answer in a second. |
