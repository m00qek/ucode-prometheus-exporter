# How-to Guides

Directions for a goal you already have. Each assumes the exporter is installed, unless it is about installing it.

## Operators

| Guide | Goal |
| :--- | :--- |
| [Installing the exporter](install.md) | Install the packages, and check that it serves. |
| [Upgrading the exporter](upgrade.md) | Move every package to a new version. |
| [Removing the exporter](uninstall.md) | Remove a collector, or everything. |
| [Moving from the feed's exporters](migrate-from-feed.md) | Replace `prometheus-node-exporter-ucode` or `-lua`, keeping their settings. |
| [Choosing collectors](choose-collectors.md) | Install, disable, or select collectors per scrape. |
| [Listening on the LAN](listen-on-lan.md) | Have Prometheus on another machine scrape it. |
| [Serving HTTPS with basic auth](https-basic-auth.md) | Ask every scrape for a password, over TLS. |
| [Compressing scrapes](gzip.md) | Check, or turn off, gzip. |
| [Giving programs more time](exec-timeout.md) | Set the seconds a collector's programs get. |
| [Setting a collector's options](collector-options.md) | Change what a collector writes. |
| [Publishing metrics from scripts](textfile.md) | Serve your own metrics through textfile. |
| [Pushing metrics from the router](push-metrics.md) | Send a scrape from cron to a Pushgateway or VictoriaMetrics. |
| [Monitoring with the bundled dashboards and alerts](dashboards-and-alerts.md) | Load the alerting rules into Prometheus or vmalert, and the dashboards into Grafana or Perses. |
| [Monitoring Unbound](unbound.md) | Give Unbound a control socket the exporter can read. |
| [Monitoring chrony](chrony.md) | Watch chronyd's synchronization, sources and server. |
| [Monitoring SQM and CAKE](sqm-cake.md) | Watch SQM's shaping: drops, delays, ECN marks. |
| [Using the LuCI app](luci.md) | Do the above from LuCI. |
| [Troubleshooting](troubleshoot.md) | Find why the service, a collector or a scrape fails. |

## Collector authors

| Guide | Goal |
| :--- | :--- |
| [Writing a collector in your own package](collector-package.md) | Write, test and package a collector outside the exporter's tree, with its devkit. |

## Developers

| Guide | Goal |
| :--- | :--- |
| [Running the tests](developer/testing.md) | Unit, integration, lint, packages, e2e, browser. |
| [Using the lab](developer/lab.md) | Run the packages on OpenWrt in a container. |
| [Running the benchmark](developer/benchmarks.md) | Measure a collector here, on a device or in QEMU. |
| [Capturing fixtures from a device](developer/fixtures.md) | Record what a device answers, for the tests. |
| [Packaging a collector](developer/package-collector.md) | Put a new collector in a package and a group. |
| [Updating the translation template](developer/translations.md) | Keep the LuCI app's `.pot` up to date. |
| [Writing documentation](developer/documentation.md) | Preview, build and generate the docs. |
| [Setting up publishing](developer/setup-docs-publishing.md) | Publish the docs for the first time. |
| [Publishing a new minor release](developer/publish-minor-docs.md) | Publish `/X.Y/` and move `latest`. |
| [Publishing a patch release](developer/publish-patch-docs.md) | Republish a minor from its patch tag. |
| [Fixing the released docs](developer/fix-released-docs.md) | Correct the docs already online. |
| [Republishing a version](developer/republish-docs.md) | Publish a version again. |
| [Publishing a release to the package feed](developer/publish-to-feed.md) | Have routers install a tagged release from packages.ucode.dev. |
