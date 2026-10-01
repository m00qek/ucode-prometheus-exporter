# ucode-prometheus-exporter

Metrics of OpenWrt for Prometheus, written in ucode and served by uhttpd at `/metrics` on port 9100. It replaces the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`, with the Lua exporter's collectors ported alongside the ucode one's, under names of its own: the package `ucode-prometheus-exporter`, the service, command and configuration `prometheus-exporter`.

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full
wget -qO- http://127.0.0.1:9100/metrics
```

- **node_exporter's names.** Where the Prometheus node_exporter has a metric, the exporter writes its name, type, labels and help, so dashboards made for it work. Elsewhere, the Prometheus naming conventions.
- **A collector per package.** The base package has what every device can use; each other collector is a package of its own, and groups install several at once.
- **A jail built from what the collectors declare.** uhttpd runs the exporter in procd's jail, which holds what the installed collectors need and nothing else.
- **Nothing to observe is not a failure.** A device without radios, or with dnsmasq disabled, is not failing to read them.
- **A ubus object and a LuCI app.** Ask the exporter what it would do, from a script or from LuCI.

It targets OpenWrt 25.12 and uses no ucode API newer than that release's. Apache License 2.0.

## Documentation map

### [Tutorials](tutorials/index.md)
**Learning-oriented.** Monitor a router with Prometheus, from installing the exporter to graphing the router. And, for developers, a first collector, from source to the lab.

### [How-to guides](how-to/index.md)
**Goal-oriented.** Install, upgrade, move from the feed's exporters, listen on the LAN, serve HTTPS with basic auth, choose collectors, set their options, monitor Unbound, chrony and SQM, troubleshoot. Plus developer tasks.

### [Reference](reference/index.md)
**Information-oriented.** Every collector and metric, every option, the service's commands, the HTTP endpoint, the ubus object, the jail, the collector interface, log messages and error codes.

### [Explanation](explanation/index.md)
**Understanding-oriented.** Why a rewrite, the architecture, the security model, nothing to observe, the metric names, and performance on small routers.
