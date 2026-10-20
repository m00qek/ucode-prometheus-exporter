# Files and Packages

Every package is built from `openwrt/ucode-prometheus-exporter/Makefile`, is architecture-independent (`PKGARCH:=all`), and has the version `<PKG_VERSION>-r<PKG_RELEASE>`. Each collector package, each group package, the command line's package and the LuCI app depend on the base package of the very same version.

The ucode and JavaScript files they install carry no comments. The build strips them (`devenv/scripts/strip-comments.py`), and keeps a newline for each line it empties, so a line number in an error on the device is the same line in the repository.

---

## `ucode-prometheus-exporter`

The exporter, its service, its ubus object and the [base collectors](collectors.md#packages).

### Dependencies

`uhttpd`, `uhttpd-mod-ucode`, `ucode`, `ucode-mod-fs`, `ucode-mod-ubus`, `ucode-mod-uci`, `ucode-mod-rtnl`, `ucode-mod-log`, `rpcd-mod-ucode` (the ubus object), `ucode-mod-uloop` (its `status` without blocking rpcd), `ucode-mod-zlib` (gzip), `ucode-mod-digest` (basic auth's hashes).

It conflicts with `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`: apk will not install it and either of them side by side.

It makes the user and group `prometheus-exporter`, which uhttpd runs as in the service's jail. See [The jail](jail.md#the-services-user).

### Files

| Path | Content |
| :--- | :--- |
| `/etc/config/prometheus-exporter` | The configuration. A conffile: an upgrade keeps it when it was changed. See [UCI configuration](uci-config.md). |
| `/etc/config/prometheus-exporter-auth` | The hash of basic auth's password, mode 0600, kept apart from the configuration that LuCI may read. A conffile too. See [UCI configuration](uci-config.md#auth). |
| `/etc/init.d/prometheus-exporter` | The service. See [Service commands](service-commands.md). |
| `/etc/uci-defaults/prometheus-exporter-import` | Takes over a feed exporter's settings, once. See [How to move from the feed's exporters](../how-to/migrate-from-feed.md). |
| `/etc/hotplug.d/ntp/90-prometheus-exporter` | Keeps busybox ntpd's last event for timesync. |
| `/usr/libexec/prometheus-exporter/handler.uc` | uhttpd's handler for `/metrics`. |
| `/usr/libexec/prometheus-exporter/check.uc` | The check. `service prometheus-exporter check` runs it, and start and reload run `check.uc --config`. The command line's `check` runs the same. |
| `/usr/libexec/prometheus-exporter/status.uc` | What `status` prints of a running service. |
| `/usr/libexec/prometheus-exporter/jail.uc` | Prints the jail's mounts. `--missing` prints the paths not there yet. `--make` makes the directories the service makes, and grants its user what the collectors declare. `--clean` takes away what it granted, when the service stops. |
| `/usr/libexec/prometheus-exporter/auth.uc` | Writes or removes basic auth's file. |
| `/usr/libexec/prometheus-exporter/watch.uc` | The `watch` instance. |
| `/usr/libexec/prometheus-exporter/import.uc` | The import the uci-defaults script runs. |
| `/usr/libexec/prometheus-exporter/rpc-status.uc` | The scrape of the ubus object's `status`. |
| `/usr/libexec/prometheus-exporter/trial.uc` | What runs in the service's jail for `check`, `status` and the command line's `scrape`. |
| `/usr/libexec/prometheus-exporter/probe.uc` | Loads collector modules in a process of its own, for rpcd: rpcd loads no module it has not seen load there first. |
| `/usr/share/rpcd/ucode/prometheus-exporter.uc` | rpcd's plugin: the [ubus object](ubus.md). |
| `/usr/share/acl.d/prometheus-exporter.json` | A link to `/var/run/prometheus-exporter.acl.json`, the service's ubus ACL, which ubusd reads. See [The jail](jail.md#the-ubus-acl). |
| `/usr/share/ucode/prometheus/exporter.uc` | The collector API, `prometheus.exporter`: the only module a collector imports. See [Collector interface](collector-interface.md#the-collector-api). |
| `/usr/share/ucode/prometheus/exporter/*.uc` | The exporter's modules, `prometheus.exporter.<module>`, except the command line's (`cli.uc`, `conform.uc`). `version.uc` holds the package's version. |
| `/usr/share/ucode/prometheus/exporter/config/*.uc` | The modules split out of `config.uc`: the options' types and datatypes. |
| `/usr/share/ucode/prometheus/exporter/exposition/*.uc` | The modules split out of `exposition.uc`. |
| `/usr/share/ucode/prometheus/exporter/deps/*.uc` | The capabilities of `deps.uc`, a module each. |
| `/usr/share/ucode/prometheus/exporter/rpc/*.uc` | The modules split out of `rpc.uc`: what `collectors` describes, and `validate`. |
| `/usr/share/ucode/prometheus/collectors/<module>.uc` | The base collectors, `prometheus.collectors.<module>`. |

### At run time

| Path | Content |
| :--- | :--- |
| `/var/run/prometheus-exporter/` | Mode 0700, root's. |
| `/var/run/prometheus-exporter/uhttpd.conf` | Basic auth's file, mode 0640, root's and the service's group's, while basic auth is on. |
| `/var/run/prometheus-exporter/tls.crt`, `tls.key` | Copies of `cert` and `key`, mode 0640, root's and the service's group's, while the service runs over HTTPS. |
| `/var/run/prometheus-exporter/capabilities.json` | The capabilities of the jail, while the service runs. |
| `/var/run/prometheus-exporter.acl.json` | The service's ubus ACL, while the service runs. |
| `/var/run/prometheus-exporter/state/` | The handler's state, each scrape's progress file, and the file that carries its collectors' runs back to it. See [The jail](jail.md#state). |
| `/var/run/prometheus-exporter/timesync/ntpd` | busybox ntpd's last event. |

All are on tmpfs: none survives a reboot.

busybox ntpd runs `/usr/sbin/ntpd-hotplug` on a step, a new stratum, a loss of sync, and periodically. procd hands each `hotplug.d/ntp` script ntpd's environment: `ACTION`, `stratum`, `offset`, `freq_drift_ppm` and `poll_interval`. chrony's own hotplug call has no `stratum`, so the script keeps nothing of it. The script writes the file whole and renames it into place, so timesync never reads half a file.

## `ucode-prometheus-exporter-cli`

The command line, [`prometheus-exporter`](command.md). It prints a scrape on standard output, runs the check, lists the installed collectors, checks a collector module before it is installed, and hashes a password. The service, its check, its ubus object and LuCI need none of it.

It depends on the base package of the very same version, and on `ucode-docopt`, which parses the command's arguments. `ucode-docopt` comes from the same feed as the exporter, and nothing else depends on it. The package takes 16 KiB installed, and `ucode-docopt` 43 KiB.

| Path | Content |
| :--- | :--- |
| `/usr/bin/prometheus-exporter` | The command. See [The `prometheus-exporter` command](command.md). |
| `/usr/share/ucode/prometheus/exporter/cli.uc` | Its commands, and the usage docopt parses its arguments by. |
| `/usr/share/ucode/prometheus/exporter/conform.uc` | `collector check`: a collector module checked against the collector contract. |

## Collector packages

`ucode-prometheus-exporter-<name>`, one per collector not in the base package. Each installs `/usr/share/ucode/prometheus/collectors/<module>.uc`, and depends on the base package and on what its collector needs: see [Collectors](collectors.md).

Installing or removing one reloads the service if it is enabled or running, which grants or takes back what the collector declares. If the service is neither, removing one takes back all the service granted (`jail.uc --clean`). Removing the base package does that too, before its files go.

`ucode-prometheus-exporter-filesystem` also installs an rpcd plugin, `/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc`. It serves the ubus object `prometheus-exporter.filesystem`. Its `mounts` method answers each of the host's mounts with its type, read-only flag, sizes and inodes: `{ result: [ { device, mount, fstype, ro, size, free, avail, files, ffree } ] }`. It reads the host's `/proc/mounts` and calls statvfs() on its mounts, which the collector cannot do from the jail. Installing or removing the package also reloads rpcd. See [ubus object](ubus.md#prometheus-exporterfilesystem).

## Group packages

`ucode-prometheus-exporter-network`, `-wireless`, `-hardware` and `-full` install no files: each depends on its collectors' packages. Removing a group from a device's world lets apk remove its collectors too. [Collectors](collectors.md#packages) lists the collectors in each group.

## `ucode-prometheus-exporter-devkit`

Tests collectors under utest. It installs its modules to `/usr/share/ucode/prometheus/exporter/devkit/`, and the mocks' proxies to `devkit/proxies/`. It depends on the base package of the same release, `ucode-utest`, `ucode-mod-nl80211` and `ucode-mod-socket`. It is for a development machine or a CI image, not a router: see [The devkit](devkit.md).

## `luci-app-prometheus-exporter`

LuCI's pages for the exporter. It depends on `luci-base` and the base package. [LuCI app](luci.md#files) lists its files. Installing or removing it clears LuCI's caches and reloads rpcd.

## Source tree

| Path | Content |
| :--- | :--- |
| `src/prometheus/exporter.uc` | The collector API, installed to `/usr/share/ucode/prometheus/exporter.uc`. |
| `src/prometheus/exporter/` | The modules, installed to `/usr/share/ucode/prometheus/exporter/`. |
| `src/prometheus/collectors/` | The collectors, installed to `/usr/share/ucode/prometheus/collectors/`. |
| `src/prometheus/exporter/devkit/` | The devkit, installed by its own package: what the tests of every collector run on. |
| `devkit/template/` | The template of a collector in a package of its own: its Makefile, module, test and fixtures. |
| `files/` | What the base package installs besides the modules. |
| `luci/` | The LuCI app. |
| `openwrt/ucode-prometheus-exporter/Makefile` | The package Makefile. |
| `test/unit/` | Unit tests; `test/unit/prometheus/` mirrors `src/prometheus/`. |
| `test/integration/` | Integration tests. |
| `test/fixtures/` | What devices answered, for the tests. |
| `test/bench/` | The benchmark. |
| `test/browser/` | The LuCI app's Playwright tests. |
| `test/docs/` | The documentation tooling's tests. |
| `devenv/` | The development environment: Docker images and scripts. |
| `docs/` | This documentation. |
