# ucode-prometheus-exporter

Metrics of OpenWrt for Prometheus, written in ucode and served by uhttpd at `/metrics` on port 9100. A rewrite of the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`, with the Lua exporter's collectors ported alongside the ucode one's, node_exporter's metric names, and a jail built from what each collector declares. It targets OpenWrt 25.12.

**[Documentation](https://m00qek.github.io/ucode-prometheus-exporter/latest/)** · [Monitor a router with Prometheus](https://m00qek.github.io/ucode-prometheus-exporter/latest/tutorials/monitor-a-router/) · [Collectors](https://m00qek.github.io/ucode-prometheus-exporter/latest/reference/collectors/) · [Renamed metrics](docs/metrics.md)

## Install

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full
wget -qO- http://127.0.0.1:9100/metrics
service prometheus-exporter check
```

The base package has the collectors every device can use; each other collector is a package of its own, and the `-network`, `-wireless`, `-hardware` and `-full` groups install several. It conflicts with the feed's exporters and takes over their settings: see [Moving from the feed's exporters](https://m00qek.github.io/ucode-prometheus-exporter/latest/how-to/migrate-from-feed/).

## Develop

Everything runs in Docker, on OpenWrt's own images.

```sh
make test        # unit and integration tests
make lint        # on 25.12's ucode; also checks the generated docs
make lab         # the packages on OpenWrt under procd, with LuCI on :8080
make docs-serve  # the documentation, live
```

[Write your first collector](https://m00qek.github.io/ucode-prometheus-exporter/latest/tutorials/first-collector/) is the place to start; every target is in [Make targets](https://m00qek.github.io/ucode-prometheus-exporter/latest/reference/make-targets/).

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
