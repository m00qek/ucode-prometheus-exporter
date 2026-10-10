# About Versions

Releases are semantic versions, `X.Y.Z`, tagged `vX.Y.Z`. This page is about what each part promises to someone who builds on the exporter, and how the packages and the documentation follow the version.

---

## What a version promises

People build on the exporter in several ways: queries and dashboards on its metric names, scripts on its uci options and ubus methods, collectors on its collector interface, images on its package names. A version says which of those can break.

- **Major**: a metric, label or metric type renamed or removed; a uci option renamed, removed or meaning something else; a ubus method's arguments or replies changed incompatibly; `collect(deps, out, options)`, `meta` or the collector API changed incompatibly (a name it exports removed, or meaning something else); a package or group renamed or split.
- **Minor**: new collectors, metrics, labels on new families, options, ubus methods, names the collector API exports, and new cases of nothing to observe.
- **Patch**: fixes, speed, and documentation.

A new case of nothing to observe is a minor change, though it changes what a scrape says of a collector: a collector that failed on some device now succeeds there, with `node_scrape_collector_observing` 0. Nothing that worked stops working, and an alert on failures fires less, for the right reason.

## The collector API

A collector imports one module, `prometheus.exporter`, and the loader refuses one that imports any other (see [Collector contract](../reference/collector-contract.md#what-a-collector-may-import)). That makes the API the whole of what a collector builds on in the exporter's code, beside `meta`, `collect` and the capabilities in `deps`: what it exports is what a major version protects. The modules behind it, `prometheus.exporter.result`, `.proc` and the rest, are the core's, split, renamed and changed in any release, as the core needs, because no collector can have imported them.

Without that rule, every module a collector happened to import would be a promise, and the core could not move a function without a major version, or would break a collector of someone else's package without knowing. The API lists, name by name, what is promised; the rest is free.

What a collector of another package builds on is, all of it:

- **The collector API**, the module `prometheus.exporter`: `Result`, `errors`, `services`, `proc` (`rows` among them), `exposition`, `u16` and `u32`, each name it exports.
- **Where a collector is**: `/usr/share/ucode/prometheus/collectors/<module>.uc`, which its package installs, the module `prometheus.collectors.<module>`, which its tests import.
- **The recorder, `out`**: `gauge`, `counter`, `untyped`, `batch`, `labels` and `parse`, and what each records.
- **`meta`**: its fields and what each means, those the jail derives grants from (`paths`, `configs`, `commands`, `ubus`, `capabilities`, `groups`, `proc_files`) included; and `deps`, each capability's functions.
- **The rules a module is loaded by**: strict mode, the API alone, and [a top level that only declares](../reference/collector-interface.md#the-top-level), with the functions it may call there.
- **The devkit**, what a collector's tests build on: its modules, `prometheus.exporter.devkit.collector`, `.fixtures`, `.commands` and `.rc`, and [their exports](../reference/devkit.md); `with_collector`'s config and run; and its proxies, under `/usr/share/ucode/prometheus/exporter/devkit/proxies/`, their keys and channels.

0.3.0 froze them for 1.0: a later 0.x adds to them, and only a major version breaks one. So a collector package depends on the exporter's major from 1.0 (`>=1.0.0`), and on 0.3.0 or later before it, rather than on the exact release the exporter's own packages pin.

## Before 1.0.0

Before 1.0.0, a minor version may break any of these, and says so. The project is young, the metric names and the configuration are still settling, and holding them fixed now would freeze mistakes. 1.0.0 is meant to be the first release to OpenWrt's packages feed, with the metric names and the configuration settled: from then on, a break is a major version.

## The package version

`PKG_VERSION` in the package Makefile is the release, `0.1.0`. `PKG_RELEASE`, the `-rN` of `0.1.0-r1`, counts changes to the packaging alone, a dependency or an install step, and starts again at 1 with each version. `ucode_prometheus_exporter_build_info{version="0.1.0-r1"}` reports both.

Every collector package, group and the LuCI app depends on the base package of the very same `<version>-r<release>`. A collector runs on the exporter's internals, and the LuCI app calls its ubus methods as that release has them; allowing a mix would mean testing every combination, and supporting the ones nobody tested. So an upgrade moves every package at once.

## The documentation's versions

The documentation is published per minor release, `/0.1/`, `/0.2/`, with `/latest/` for the newest, as [About versioned documentation](versioned-docs.md) explains. A patch release replaces its minor's docs, since a patch changes no option, metric or method. A router on 0.1 reads the 0.1 docs, where the options and metrics are the ones it has.
