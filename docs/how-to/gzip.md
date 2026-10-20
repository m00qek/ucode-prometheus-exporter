# How to Compress Scrapes

The exporter gzips a scrape when the scraper asks for it with `Accept-Encoding: gzip`. Prometheus and vmagent send that header by default. Compression is on unless you turned it off.

## Check that scrapes are compressed

```sh
curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' http://router.lan:9100/metrics
```

A compressed reply has `Content-Encoding: gzip`. While compression is on, `service prometheus-exporter status` says `gzip when asked`, and LuCI's **Status → Prometheus exporter** says **Compression**: **gzip, when the scraper asks for it**.

## Turn it off

Turn it off if the scraper's CPU, or the router's, matters more than the bytes on the network:

=== "Browser (LuCI)"

    On **Services → Prometheus exporter**, tab **General**, untick **Compress**, and press **Save & Apply**.

=== "Terminal (SSH)"

    ```sh
    uci set prometheus-exporter.main.compress=0
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```

Scrapes are then plain text, whatever the scraper asks for.

## Turn it back on

=== "Browser (LuCI)"

    On **Services → Prometheus exporter**, tab **General**, tick **Compress**, and press **Save & Apply**.

=== "Terminal (SSH)"

    ```sh
    uci set prometheus-exporter.main.compress=1
    uci commit prometheus-exporter
    service prometheus-exporter reload
    ```

## For one scraper only

Leave `compress` on, and make the scraper that wants plain text stop asking for gzip. In Prometheus 2.49 and later, set `enable_compression: false` in its scrape config. The exporter also answers plain text to a request with `Accept-Encoding: gzip;q=0`.

---

[Performance on small routers](../explanation/performance.md#gzip) says what a compressed scrape saves and costs. [HTTP endpoint](../reference/http.md#compression) has the rules of the reply.
