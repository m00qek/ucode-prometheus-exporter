# HTTP Endpoint

uhttpd serves the exporter's handler, `/usr/libexec/prometheus-exporter/handler.uc`, under the prefix `/metrics`, on port `listen_port` (9100) of the addresses of `listen_interface` (`loopback`), or of every address for `*`. With `cert` and `key` both set and both there it serves HTTPS, otherwise HTTP. See [UCI configuration](uci-config.md#main).

---

## Requests

| Request | Answer |
| :--- | :--- |
| `/metrics`, any method | A scrape. |
| A path under `/metrics`, such as `/metrics/x` | The same scrape: uhttpd hands the handler every path with that prefix. |
| Any other path | 404, from uhttpd: its document root is `/dev/null`. |

## Query string

| Parameter | Meaning |
| :--- | :--- |
| `collect[]=<name>` | Scrape this collector. Repeat it for several; they are scraped in the order given, once each. |
| `collect=<name>` | The same, as the feed's ucode exporter spelled it. |
| `exclude[]=<name>` | Leave this collector out. |

A name is a collector's name (`ltq-dsl`) or its module (`ltq_dsl`), URL-encoded or not. Without `collect[]`, a scrape selects every enabled collector, in the order of their names, less those excluded; the reply is in that order. Other parameters are ignored.

## Request headers

| Header | Meaning |
| :--- | :--- |
| `X-Prometheus-Scrape-Timeout-Seconds` | The seconds the scraper waits, as Prometheus and vmagent send it: a positive number, as `10` or `9.5`. Without it, or with a value that is not one, the main section's `scrape_timeout` (10). Never more than 60, uhttpd's `-t`. |
| `Accept-Encoding` | Whether the scraper takes gzip: [Compression](#compression). |
| `Authorization` | Basic auth: [Basic auth](#basic-auth). |

## Deadline

A scrape's collectors get the timeout less 0.5 seconds, or half of it when that is less, counted from when the request reaches the handler. The collectors run fastest first, by how long each took before (a collector never timed after the others), and a collector is started only if what it took before, and the reply's writing, still fit:

- A collector left out fails with `SCRAPE_DEADLINE`; so does one whose program was killed at the deadline. A program gets the whole seconds left, and is not started with less than one.
- A collector quarantined by its circuit breaker is not run, even when `collect[]` names it: it fails with `COLLECTOR_QUARANTINED`, and its `ucode_prometheus_exporter_collector_quarantined` is 1.
- The scrape logs those the deadline left out in one line: see [Log messages](log-messages.md#the-handler).

See [About deadlines and circuit breakers](../explanation/deadlines-and-breakers.md).

| Query | Status | Body |
| :--- | :--- | :--- |
| Names only installed, enabled collectors | `200 OK` | The scrape. |
| Names a collector that is not installed, in `collect[]` or `exclude[]` | `400 Bad Request` | `COLLECTOR_INVALID (unknown collector '<name>')` |
| Names a disabled collector in `collect[]` | `400 Bad Request` | `COLLECTOR_INVALID (collector '<name>' is disabled)` |

## The scrape

`Content-Type: text/plain; version=0.0.4; charset=utf-8`: the Prometheus text exposition format, version 0.0.4.

- Each collector's families. A family is one collector's: the first of the reply that writes it, the exporter's own collectors before those of other packages; another that writes it fails with `FAMILY_CONFLICT`, and none of its samples are served (see [Collector contract](collector-contract.md)). Within a collector, a family declared with two types keeps the first, drops the later samples, and logs a warning.
- Then, for every collector selected: `node_scrape_collector_duration_seconds` (0 for one not run), `node_scrape_collector_success`, `node_scrape_collector_observing` and `ucode_prometheus_exporter_collector_quarantined`, labeled `collector`. Then `ucode_prometheus_exporter_build_info{version}`. See [Metrics](metrics.md#scrape).
- A collector that fails keeps the samples it wrote before it failed. One with nothing to observe writes none.
- With `option omit_zero_values '1'`, samples of counters whose value is 0 are left out.

A collector's failure does not fail the scrape: the answer is still `200 OK`.

## Compression

While `option compress` is `1` (the default):

- Every reply has `Vary: Accept-Encoding`.
- A `200` reply is gzip-compressed, with `Content-Encoding: gzip`, when the request's `Accept-Encoding` takes gzip: `gzip` or `x-gzip` with a `q` other than 0, or `*` with a `q` other than 0 when it names neither. `gzip;q=0` refuses it.
- zlib's level is 1, the fastest.

With `option compress '0'`, no reply is compressed and none has `Vary`.

## Basic auth

With `auth_user` and `auth_password` set, the handler checks every request before it scrapes, against uhttpd's config file, `/var/run/prometheus-exporter/uhttpd.conf`:

| Request | Status | Headers | Body |
| :--- | :--- | :--- | :--- |
| Over HTTP | `403 Forbidden` | | `Basic auth takes HTTPS only.` |
| Without an `Authorization: Basic` header, or with a user or password that does not match | `401 Unauthorized` | `WWW-Authenticate: Basic realm="prometheus-exporter"` | `Unauthorized.` |
| With the user and password | As without basic auth | | |
| Any, when the file is there but is not one line of a user and a hash for `/metrics` | `500 Internal Server Error` | | `Basic auth is not configured as it should be; see the log.` |

These replies are `Content-Type: text/plain; charset=utf-8`. The init script never serves basic auth over HTTP: the 403 is for a request that reaches the handler without TLS all the same.

The handler reads the file, `compress` and `scrape_timeout` once, when uhttpd starts it. A change of any restarts uhttpd: see [Service commands](service-commands.md#triggers).

The password is checked against the hash: `$1$` (MD5-crypt), `$5$` (SHA-256-crypt) or `$6$` (SHA-512-crypt), of at most 2000 rounds. After a request is let in, the handler keeps a digest of its `Authorization` header in its state, and lets in a later request with the same header on the digest alone. See [The jail](jail.md#state).

## Keep-alive

uhttpd keeps an idle connection open `http_keepalive` seconds (70), with `-k`: `Keep-Alive: timeout=70`. At `0` it answers `Connection: close` and closes each connection once it has answered.

70 seconds outlasts Prometheus's default `scrape_interval` of 60: its connection stays open from one scrape to the next, and each scrape reuses it, without a new TCP connection or, over HTTPS, a new TLS handshake, which costs a router's CPU more than a scrape's request does. A scraper that scrapes less often than every 70 seconds connects again each time; set `http_keepalive` above its interval to spare it that.

## Connections

uhttpd runs at most 3 requests at once (`-n 3`), over at most 10 connections (`-N 10`), the init script says, rather than leave it to uhttpd's defaults, 3 and 100. The service is scraped by one or two Prometheus servers, each over a connection of its own that keep-alive keeps open; LuCI reaches the exporter through rpcd, not over this port. Each request is a full scrape, or with basic auth a check of the hash first: 3 at once are two scrapers' scrapes that overlap and one more, as a curl's. A request past them waits until one ends, and the connections bound how many can wait. uhttpd gives each request 60 seconds (`-t 60`), as `scrape_timeout` reckons.

The port should be reachable by the scrapers alone: whoever reaches it can make the router scrape, and hash, again and again. See [How to listen on the LAN](../how-to/listen-on-lan.md#keep-it-to-the-scrapers).

## See also

- [How to serve HTTPS with basic auth](../how-to/https-basic-auth.md)
- [How to compress scrapes](../how-to/gzip.md)
- [About the security model](../explanation/security.md)
