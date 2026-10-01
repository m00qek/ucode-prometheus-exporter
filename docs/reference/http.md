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

A name is a collector's name (`ltq-dsl`) or its module (`ltq_dsl`), URL-encoded or not. Without `collect[]`, a scrape runs every enabled collector, in the order of their names, less those excluded. Other parameters are ignored.

| Query | Status | Body |
| :--- | :--- | :--- |
| Names only installed, enabled collectors | `200 OK` | The scrape. |
| Names a collector that is not installed, in `collect[]` or `exclude[]` | `400 Bad Request` | `COLLECTOR_INVALID (unknown collector '<name>')` |
| Names a disabled collector in `collect[]` | `400 Bad Request` | `COLLECTOR_INVALID (collector '<name>' is disabled)` |

## The scrape

`Content-Type: text/plain; version=0.0.4; charset=utf-8`: the Prometheus text exposition format, version 0.0.4.

- Each collector's families, merged by name: a family two collectors write is written once, with the samples of both. A family declared with two types keeps the first, drops the later samples, and logs a warning.
- Then, for every collector that ran: `node_scrape_collector_duration_seconds`, `node_scrape_collector_success` and `node_scrape_collector_observing`, labeled `collector`. Then `ucode_prometheus_exporter_build_info{version}`. See [Metrics](metrics.md#scrape).
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

The handler reads the file, and `compress`, once, when uhttpd starts it. A change of either restarts uhttpd: see [Service commands](service-commands.md#triggers).

The password is checked against the hash: `$1$` (MD5-crypt), `$5$` (SHA-256-crypt) or `$6$` (SHA-512-crypt), of at most 2000 rounds. After a request is let in, the handler keeps a digest of its `Authorization` header in its state, and lets in a later request with the same header on the digest alone. See [The jail](jail.md#state).

## Keep-alive

uhttpd keeps an idle connection open `http_keepalive` seconds (70), with `-k`. At `0` the init script leaves `-k` out, and uhttpd keeps its own default, 20 seconds: `Keep-Alive: timeout=20`.

## See also

- [How to serve HTTPS with basic auth](../how-to/https-basic-auth.md)
- [How to compress scrapes](../how-to/gzip.md)
- [About the security model](../explanation/security.md)
