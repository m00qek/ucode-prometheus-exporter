# Files and Packages

Every package is architecture-independent (`PKGARCH:=all`), built from `openwrt/ucode-prometheus-exporter/Makefile`, version `<PKG_VERSION>-r<PKG_RELEASE>`. Each collector package, group package and the LuCI app depends on the base package of the very same version.

---

## `ucode-prometheus-exporter`

The exporter, its service, its ubus object and the [base collectors](collectors.md#packages).

### Dependencies

`uhttpd`, `uhttpd-mod-ucode`, `ucode`, `ucode-mod-fs`, `ucode-mod-ubus`, `ucode-mod-uci`, `ucode-mod-rtnl`, `ucode-mod-log`, `rpcd-mod-ucode` (the ubus object), `ucode-mod-uloop` (its `status` without blocking rpcd), `ucode-mod-zlib` (gzip), `ucode-mod-digest` (basic auth's hashes).

It conflicts with `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`: apk installs neither beside it, nor it beside either.

It makes the user and group `prometheus-exporter`, which uhttpd runs as in the service's jail: see [The jail](jail.md#the-services-user).

### Files

| Path | Content |
| :--- | :--- |
| `/etc/config/prometheus-exporter` | The configuration. A conffile: an upgrade keeps it when it was changed. See [UCI configuration](uci-config.md). |
| `/etc/config/prometheus-exporter-auth` | The hash of basic auth's password, mode 0600, apart from the configuration LuCI may read. A conffile too. See [UCI configuration](uci-config.md#auth). |
| `/etc/init.d/prometheus-exporter` | The service. See [Service commands](service-commands.md). |
| `/etc/uci-defaults/prometheus-exporter-import` | Takes over a feed exporter's settings, once. See [How to move from the feed's exporters](../how-to/migrate-from-feed.md). |
| `/etc/hotplug.d/ntp/90-prometheus-exporter` | Keeps busybox ntpd's last event for timesync. |
| `/usr/bin/prometheus-exporter` | The command; `service prometheus-exporter check` runs its `check`, and start and reload its `check --config`. See [The `prometheus-exporter` command](command.md). |
| `/usr/libexec/prometheus-exporter/handler.uc` | uhttpd's handler for `/metrics`. |
| `/usr/libexec/prometheus-exporter/status.uc` | What `status` prints of a running service. |
| `/usr/libexec/prometheus-exporter/jail.uc` | The jail's mounts; `--missing`, the paths not there yet; `--make`, the directories the service makes, and what it grants its user; `--clean`, what it takes away when it stops. |
| `/usr/libexec/prometheus-exporter/auth.uc` | Writes or removes basic auth's file. |
| `/usr/libexec/prometheus-exporter/watch.uc` | The `watch` instance. |
| `/usr/libexec/prometheus-exporter/import.uc` | The import the uci-defaults script runs. |
| `/usr/libexec/prometheus-exporter/rpc-status.uc` | The scrape of the ubus object's `status`. |
| `/usr/libexec/prometheus-exporter/trial.uc` | What runs in the service's jail for `check`, `status` and the command's `scrape`. |
| `/usr/libexec/prometheus-exporter/probe.uc` | Loads collector modules in a process of its own, for rpcd, which loads none it has not seen load. |
| `/usr/share/rpcd/ucode/prometheus-exporter.uc` | rpcd's plugin: the [ubus object](ubus.md). |
| `/usr/share/acl.d/prometheus-exporter.json` | A link to `/var/run/prometheus-exporter.acl.json`, the service's ubus ACL, which ubusd reads. See [The jail](jail.md#the-ubus-acl). |
| `/usr/share/ucode/prometheus_exporter/*.uc` | The exporter's modules. `version.uc` holds the package's version. |
| `/usr/share/ucode/prometheus_exporter/config/*.uc` | The modules split out of `config.uc`: the options' types and datatypes. |
| `/usr/share/ucode/prometheus_exporter/exposition/*.uc` | The modules split out of `exposition.uc`. |
| `/usr/share/ucode/prometheus_exporter/deps/*.uc` | The capabilities of `deps.uc`, a module each. |
| `/usr/share/ucode/prometheus_exporter/rpc/*.uc` | The modules split out of `rpc.uc`: what `collectors` describes, and `validate`. |
| `/usr/share/ucode/prometheus_exporter/collectors/<module>.uc` | The base collectors. |

### At run time

| Path | Content |
| :--- | :--- |
| `/var/run/prometheus-exporter/` | Mode 0700, root's. |
| `/var/run/prometheus-exporter/uhttpd.conf` | Basic auth's file, mode 0640, root's and the service's group's, while basic auth is on. |
| `/var/run/prometheus-exporter/tls.crt`, `tls.key` | Copies of `cert` and `key`, mode 0640, root's and the service's group's, while the service runs over HTTPS. |
| `/var/run/prometheus-exporter/capabilities.json` | The capabilities of the jail, while the service runs. |
| `/var/run/prometheus-exporter.acl.json` | The service's ubus ACL, while the service runs. |
| `/var/run/prometheus-exporter/state/` | The handler's state, and each scrape's progress file and the file its collectors' runs cross by. See [The jail](jail.md#state). |
| `/var/run/prometheus-exporter/timesync/ntpd` | busybox ntpd's last event. |

All are on tmpfs: none survives a reboot.

## Collector packages

`ucode-prometheus-exporter-<name>`, one per collector not in the base package. Each installs `/usr/share/ucode/prometheus_exporter/collectors/<module>.uc` and depends on the base package and on what its collector needs: see [Collectors](collectors.md). Installing or removing one reloads an enabled service.

`ucode-prometheus-exporter-filesystem` installs besides an rpcd plugin, `/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc`: the ubus object `prometheus-exporter.filesystem`, whose `mounts` is luci's `getMountPoints` with each mount's inodes, `{ result: [ { device, mount, size, free, avail, files, ffree } ] }`, the statvfs() of the host's mounts the jail cannot make. Installing or removing the package reloads rpcd too. See [ubus object](ubus.md#prometheus-exporterfilesystem).

## Group packages

`ucode-prometheus-exporter-network`, `-wireless`, `-hardware` and `-full` install no files: each depends on its collectors' packages. Removing a group from a device's world lets apk remove its collectors too. Which collectors each holds is in [Collectors](collectors.md#packages).

## `luci-app-prometheus-exporter`

LuCI's pages for the exporter. Depends on `luci-base` and the base package. Its files are in [LuCI app](luci.md#files). Installing and removing it clears LuCI's caches and reloads rpcd.

## Source tree

| Path | Content |
| :--- | :--- |
| `src/prometheus_exporter/` | The modules, installed to `/usr/share/ucode/prometheus_exporter/`. |
| `src/prometheus_exporter/collectors/` | The collectors. |
| `files/` | What the base package installs besides the modules. |
| `luci/` | The LuCI app. |
| `openwrt/ucode-prometheus-exporter/Makefile` | The package Makefile. |
| `test/unit/` | Unit tests; `test/unit/prometheus_exporter/` mirrors `src/prometheus_exporter/`. |
| `test/integration/` | Integration tests. |
| `test/fixtures/` | What devices answered, for the tests. |
| `test/bench/` | The benchmark. |
| `test/browser/` | The LuCI app's Playwright tests. |
| `test/docs/` | The documentation tooling's tests. |
| `devenv/` | The development environment: Docker images and scripts. |
| `docs/` | This documentation. |
