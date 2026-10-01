# How to Compress Scrapes

The exporter gzips a scrape when the scraper asks for it, `Accept-Encoding: gzip`, which Prometheus and vmagent send by default. It is on unless you turned it off.

## Check that scrapes are compressed

```sh
curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' http://router.lan:9100/metrics
```

A compressed reply has `Content-Encoding: gzip`. `service prometheus-exporter status` says `gzip when asked` while it is on.

## Turn it off

If the scraper's CPU, or the router's, matters more than the bytes on the network:

```sh
uci set prometheus-exporter.main.compress=0
uci commit prometheus-exporter
service prometheus-exporter reload
```

Scrapes are then plain text, whatever the scraper asks.

## Turn it back on

```sh
uci set prometheus-exporter.main.compress=1
uci commit prometheus-exporter
service prometheus-exporter reload
```

## For one scraper only

Leave `compress` on, and have the scraper that wants plain text not ask: in Prometheus, `enable_compression: false` in its scrape config (Prometheus 2.49 and later). A request with `Accept-Encoding: gzip;q=0` is answered plain too.

---

What a compressed scrape saves, and costs, is in [Performance on small routers](../explanation/performance.md#gzip). The rules of the reply are in [HTTP endpoint](../reference/http.md#compression).
