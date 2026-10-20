# ucode-prometheus-exporter

Metrics of OpenWrt for Prometheus, written in ucode and served by uhttpd at `/metrics` on port 9100. It replaces the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`. It ports the Lua exporter's collectors alongside the ucode one's, under names of its own: the package is `ucode-prometheus-exporter`, and the service, command and configuration are `prometheus-exporter`.

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-full
wget -qO- http://127.0.0.1:9100/metrics
```

- **node_exporter's names.** Where the Prometheus node_exporter has a metric, the exporter writes its name, type, labels and help, so dashboards made for node_exporter work. Other metrics follow the Prometheus naming conventions.
- **A collector per package.** The base package has the collectors every device can use. Each other collector is a package of its own, and groups install several at once.
- **A jail built from what the collectors declare.** uhttpd runs the exporter in procd's jail, which holds what the installed collectors need and nothing else.
- **Nothing to observe is not a failure.** A device without radios, or with dnsmasq disabled, is not failing to read them.
- **A ubus object and a LuCI app.** Ask the exporter what it would do, from a script or from LuCI.

It targets OpenWrt 25.12, and uses no ucode API newer than that release's. Apache License 2.0.

## Who these docs are for

| Reader | Who | Tutorial | How-tos | Reference | Explanation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Operator** | Runs the exporter on routers and watches the metrics: newcomers, people moving from the feed's exporters, LuCI-only users, security-minded admins. | [Monitor a router](tutorials/monitor-a-router.md) | [Operators](how-to/index.md#operators) | [UCI configuration](reference/uci-config.md), [Metrics](reference/metrics.md) | [Security model](explanation/security.md) |
| **Collector author** | Writes a collector, in this repository or in their own package. | [Write your first collector](tutorials/first-collector.md) | [Collector authors](how-to/index.md#collector-authors) | [Collector interface](reference/collector-interface.md) | [Nothing to observe](explanation/nothing-to-observe.md) |
| **Maintainer** | Builds, tests, releases and publishes this repository. | [Write your first collector](tutorials/first-collector.md) | [Maintainers](how-to/index.md#maintainers) | [Make targets](reference/make-targets.md) | [Architecture](explanation/architecture.md) |

## Documentation map

### [Tutorials](tutorials/index.md)
**Learning-oriented.** Monitor a router with Prometheus, from installing the exporter to graphing the router. And, for developers, a first collector, from source to the lab.

### [How-to guides](how-to/index.md)
**Goal-oriented.** Install, upgrade, move from the feed's exporters, listen on the LAN, serve HTTPS with basic auth, choose collectors, set their options, monitor Unbound, chrony and SQM, troubleshoot. Plus developer tasks.

### [Reference](reference/index.md)
**Information-oriented.** Every collector and metric, every option, the service's commands, the HTTP endpoint, the ubus object, the jail, the collector interface, log messages and error codes.

### [Explanation](explanation/index.md)
**Understanding-oriented.** Why a rewrite, the architecture, the security model, nothing to observe, the metric names, and performance on small routers.
