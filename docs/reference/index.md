# Reference

Technical descriptions of the exporter, to consult while you work. Four pages are generated from the code by `make docs-gen`: [Collectors](collectors.md), [Metrics](metrics.md), [UCI configuration](uci-config.md) and [Error codes](error-codes.md).

## What it collects

| Page | Content |
| :--- | :--- |
| [Collectors](collectors.md) | Every collector: its package and groups, options, configs, programs, jail paths, and when it has nothing to observe. |
| [Metrics](metrics.md) | Every metric family, by collector: type, labels and help. |
| [Renamed metrics](../metrics.md) | The names that changed from the feed's exporters, and why. |

## Configuring and running it

| Page | Content |
| :--- | :--- |
| [UCI configuration](uci-config.md) | Every option of `/etc/config/prometheus-exporter`, and what values it takes. |
| [Service commands](service-commands.md) | The init script's actions, `status` and `check`, procd's instances and triggers. |
| [The `prometheus-exporter` command](command.md) | A scrape on the command line. |
| [HTTP endpoint](http.md) | `/metrics`: the query string, the reply, compression, basic auth. |
| [ubus object](ubus.md) | `prometheus-exporter`'s methods, arguments and replies. |
| [LuCI app](luci.md) | Its pages, fields and ACL. |
| [The jail](jail.md) | What procd's jail mounts, and the state the exporter keeps. |
| [Log messages](log-messages.md) | Every line the exporter logs, and its priority. |
| [Error codes](error-codes.md) | The codes of a failure, and where each is raised. |
| [Files and packages](files.md) | What each package installs and depends on. |

## Developing it

| Page | Content |
| :--- | :--- |
| [Collector interface](collector-interface.md) | `meta`, `collect(deps, out, options)`, the capabilities and Results. |
| [Make targets](make-targets.md) | The targets of the root `Makefile` and `docs/Makefile`, and their variables. |
| [Documentation publishing](docs-publishing.md) | How the versioned site is published. |
