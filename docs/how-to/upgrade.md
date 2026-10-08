# How to Upgrade the Exporter

Every collector package, group and the LuCI app depends on the base package of the very same version, so they move together.

## Before you upgrade

Read what the new version changes. Before 1.0.0 a minor version may rename metrics or options: see [About versions](../explanation/versions.md). A renamed metric breaks the queries and dashboards that use the old name.

---

## From the feed

With the exporter's feed added, as [How to install the exporter](install.md#1-add-the-feed) adds it:

```sh
apk update
apk upgrade
```

## From `.apk` files

Copy every package you have installed, in the new version, to the device's `/tmp`, and add them in one command, `version` set to the new version as the files' names end:

```sh
version=0.2.0-r1
apk add --allow-untrusted /tmp/ucode-prometheus-exporter-*$version.apk /tmp/luci-app-prometheus-exporter-$version.apk
```

Adding the base package alone fails: the installed collectors still want the old version. A dependency the new version adds comes from the feeds the device has: `ucode-docopt`, which 0.2 added, from the exporter's feed.

## From 0.2.0 to 0.2.1

0.2.1 changes what 0.2.0 did in these ways:

- **Basic auth's hash has a config of its own.** `auth_password` is read from `/etc/config/prometheus-exporter-auth`, which the package installs, mode 0600, and no longer from the main section of `/etc/config/prometheus-exporter`, which LuCI's ACL lets a login read. The upgrade moves a hash it finds in the main section, and logs `auth_password moved from /etc/config/prometheus-exporter to /etc/config/prometheus-exporter-auth`. A script that sets the hash sets `prometheus-exporter-auth.main.auth_password`, or calls the ubus object's `set_password`; `check` warns of a hash left in the main section, which is ignored. See [How to serve HTTPS with basic auth](https-basic-auth.md).
- **A hash without a user is no basic auth**, rather than an invalid configuration: `validate` no longer answers `AUTH_NEEDS_USER`. Basic auth is on while `auth_user` is set.
- **LuCI's ACL grants `password` and `set_password`**, and no longer `hash_password`, which LuCI does not call: a login given the app's ACL reads whether a hash is saved, never the hash.
- **textfile's `directory` must be under `/var`, `/tmp` or `/etc/prometheus-exporter`.** The service makes and mounts no other: move one elsewhere, as under `/srv`, before upgrading, or the configuration is refused (`OWNED_DIRECTORY`).
- **`memory_limit` takes 0, or 8 MB and more.** 1 to 7 passed `check`, and uhttpd crash-looped; they are refused now (`ZERO_OR_MIN`).
- **The jail has the ubus socket only while an enabled collector needs ubus.** A collector of another package whose programs call ubus, without `ubus` in its `meta.needs`, finds no ubus when every other collector that needs it is disabled: declare it.

## From 0.1 to 0.2

0.2.0 changes what 0.1 did in these ways:

- **The command line takes subcommands.** `prometheus-exporter [COLLECTOR...]` is `prometheus-exporter scrape [COLLECTOR...]`, and `prometheus-exporter -l` is `prometheus-exporter collector list`. A script or cron job that runs the command needs the new form: see [The prometheus-exporter command](../reference/command.md).
- **wifi_stations is gone.** It wrote the very families wifi's option `stations` writes, so each station was exported twice. Remove `ucode-prometheus-exporter-wifi_stations` before the upgrade (`apk del ucode-prometheus-exporter-wifi_stations`), and install `ucode-prometheus-exporter-wifi` if it is not there: its `stations` is on by default.
- **A collector's package no longer installs what it watches.** The packages of mwan3, chrony, modemmanager, ubnt-manager and wireguard depended on mwan3, chrony, modemmanager, ubnt-manager and rpcd-mod-wireguard: installing the mwan3 collector installed and started mwan3, which changes the routing, and the chrony one a second NTP daemon. They depend on none of them now; where it is not there, the collector has nothing to observe. An upgrade removes nothing: apk keeps what was installed. If one was installed only for its collector, remove it (`apk del mwan3`, say).
- **A collector imports the collector API alone.** A collector module imports `prometheus_exporter.api`, which exports `Result`, `errors`, `services`, `proc` and `exposition`, and no other module: one that imports `prometheus_exporter.result`, `fs` or any other is left out, logged at `err`. Every collector of the exporter's packages already does. A collector of another package written for 0.1, should one exist, takes the same names from the API: `import { Result, errors, proc } from 'prometheus_exporter.api';`, and `proc.first_line(...)` for `first_line(...)`. Check it with `prometheus-exporter collector check`. See [Collector contract](../reference/collector-contract.md#what-a-collector-may-import).
- **A collector's options need a title.** Each option of `meta.options` declares `title`, the label LuCI's Edit dialog shows it by, short and in sentence case: `device_exclude: { default: '...', title: 'Excluded devices', help: '...' }`. A collector with an option that has none is left out, logged at `err`. Every collector of the exporter's packages has them. See [Collector interface](../reference/collector-interface.md#options).
- **The ubus object's `validate` answers codes.** Each value it refuses was an English sentence; it is an object now, `{ code, ...arguments, message }`, as `{ "code": "RANGE", "min": 1, "max": 65535, "value": 0, "message": "expected an integer from 1 to 65535, got 0" }`, whose `message` is the sentence. A script that reads the reply reads `message`, or the code: see [ubus object](../reference/ubus.md#validate). `check`, the log and the command line say what they said.
- **A collector that breaks the collector contract fails alone**: it is stopped at its budget, at its `max_samples`, or when it writes another collector's family. See [Collector contract](../reference/collector-contract.md).

## Check the result

```sh
wget -qO- http://127.0.0.1:9100/metrics | grep build_info
service prometheus-exporter check
```

`ucode_prometheus_exporter_build_info{version="..."}` is the new version. The upgrade restarts a running service; `/etc/config/prometheus-exporter` stays as you had it. If you changed it, apk may leave the new version's file beside it, as `/etc/config/prometheus-exporter.apk-new`: compare the two, and remove it once you have taken what you want.
