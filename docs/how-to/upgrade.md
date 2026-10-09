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

## From 0.2.1 to 0.3.0

0.3.0 is the first release candidate for 1.0: the names and labels of its metrics are those 1.0 keeps. It changes what 0.2.1 did in these ways, each marked **BREAKING** in the [CHANGELOG](https://github.com/m00qek/ucode-prometheus-exporter/blob/main/CHANGELOG.md):

- **snmp6 exports 13 fields of each device by default**, where it wrote every one, some 70. Gone by default: every `node_snmp6_*_total` but the device's `Ip6_InOctets`, `Ip6_OutOctets`, `Ip6_OutForwDatagrams`, `Ip6_InDiscards`, `Ip6_OutDiscards`, `Ip6_InNoRoutes`, `Ip6_OutNoRoutes`, `Ip6_InHdrErrors`, `Ip6_InAddrErrors`, `Ip6_InTooBigErrors`, `Icmp6_InMsgs`, `Icmp6_OutMsgs` and `Icmp6_InErrors`, and `node_snmp6_ifindex`, whose index netclass's `node_network_iface_id` has too. Its new option `fields`, a regular expression of `<Protocol>_<Field>`, takes others; `.*` exports every one, as 0.2.1 did:

    ```sh
    uci set prometheus-exporter.snmp6=collector
    uci set prometheus-exporter.snmp6.fields='.*'
    uci commit prometheus-exporter
    ```

- **nat_traffic labels its series `host`, one per host on this side of the router**, where 0.2.1 wrote one per pair of addresses, labeled `src` and `dst`. `node_nat_traffic_bytes{src,dst}` is `node_nat_traffic_bytes{host}`: the source of each connection, as `src` was, but for a port-forwarded connection the LAN host it reaches, where `src` was the remote address. A query by `src` is one by `host`, as `node_nat_traffic_bytes{host="192.168.1.10"}`; one by `dst` needs the pairs, which are back with the new option `peers`, labeled `host` and `peer`, as many series as 0.2.1 wrote, new with every connection; a Prometheus server keeps each for hours, so leave it off but for a short look:

    ```sh
    uci set prometheus-exporter.nat_traffic=collector
    uci set prometheus-exporter.nat_traffic.peers=1
    uci commit prometheus-exporter
    ```

- **The jail no longer runs as root.** uhttpd runs in it as the user and group `prometheus-exporter`, which the upgrade makes. The upgrade restarts a running service, which then grants that user what its enabled collectors declare, and nothing needs doing: its state directory is the user's, and starts empty, as at every restart; basic auth's file is written again for the user's group to read; the TLS key and certificate are copied for it, and the files themselves stay as they were, the key root's alone; the configs its collectors read are opened to its group, read-only. See [The jail](../reference/jail.md#the-services-user).
- **textfile's files must be readable by the service's user.** A script that writes a `*.prom` file only root reads (mode 0600, as `mktemp` makes one) has it skipped, and logged: `chmod 0644` it before renaming it into place. See [How to publish metrics from scripts](textfile.md).
- **A collector of another package that calls ubus must declare its calls**, in `meta.ubus`, as `ubus: { dnsmasq: [ 'metrics' ], rc: [ 'list' ] }` (`rc list` for the API's `services`): the loader refuses one that needs ubus without them, and a call it does not declare fails, `UBUS_NOT_ALLOWED`. One that reads a root-only file of `/proc`, needs a capability, or connects to a socket of another service's group declares it too: `proc_files`, `capabilities`, `groups`. Every collector of the exporter's packages does; check one of another package with `prometheus-exporter collector check`. See [Collector interface](../reference/collector-interface.md#meta).
- **A collector's top level must only declare.** It runs again in uhttpd's own process each time the service starts, where nothing stops it: there, and in the child process that first loads it, a top level that calls `sleep`, `exit`, `print`, `printf`, `warn`, `trace`, `require`, `include`, `loadfile`, `loadstring`, `render` or `signal`, or the collector API's `exposition` functions, is refused before the call runs, and the collector is left out, logged at `err` as `COLLECTOR_IMPURE`. Every collector of the exporter's packages only declares; move what one of another package does at its top level into `collect()`, and check it with `prometheus-exporter collector check`, which now reads its text for statements and calls past the declarations too. See [Collector interface](../reference/collector-interface.md#the-top-level).


These change what 0.2.1 did without breaking a query or a configuration:

- **ethtool runs ethtool three times a device**, `-S`, `-i` and with no option, where it ran it once, for node_exporter's `node_ethtool_info` and link families. Its programs share the seconds of its `timeout` (the main section's `exec_timeout`, 5, by default): on a slow router with many ports, give it more if it fails with `COMMAND_TIMEOUT`. See [How to give programs more time](exec-timeout.md).
- **The filesystem package installs an rpcd plugin**, the ubus object `prometheus-exporter.filesystem`, for the inodes of each mount, and reloads rpcd when it is installed or removed.
- **Two new collectors, each a package of its own, installed by no group**: `pressure`, pressure stall information, which needs a kernel with `CONFIG_PSI` (OpenWrt's leave it off), and `interrupts`. Install the package to use one: `apk add ucode-prometheus-exporter-pressure`. See [How to choose collectors](choose-collectors.md#install-collectors).
- **LuCI changes basic auth's password with its own button, Change password…**, on the HTTPS & login tab, where 0.2.1 had a field that Save handed on. It still applies at once, apart from Save & Apply, and the dialog takes the password twice; **Remove password** removes the saved one, once the user is emptied. The app's ACL is unchanged. See [How to use the LuCI app](luci.md#change-basic-auths-password).
- **A collector refused what it needs fails `PERMISSION_DENIED`**, saying what grants it, where it would have found nothing to observe: a reload grants what the service granted when it started and was taken away since.
- **`check` says the jail's user, its capabilities and its ubus ACL.** The ubus object's `describe` has each collector's calls, capabilities, groups and proc files, in its `jail`.

## From 0.2.0 to 0.2.1

0.2.1 changes what 0.2.0 did in these ways, each marked **BREAKING** in the [CHANGELOG](https://github.com/m00qek/ucode-prometheus-exporter/blob/main/CHANGELOG.md):

- **Basic auth's hash has a config of its own.** `auth_password` is read from `/etc/config/prometheus-exporter-auth`, which the package installs, mode 0600, and no longer from the main section of `/etc/config/prometheus-exporter`, which LuCI's ACL lets a login read. The upgrade moves a hash it finds in the main section, and logs `auth_password moved from /etc/config/prometheus-exporter to /etc/config/prometheus-exporter-auth`. A script that sets the hash sets `prometheus-exporter-auth.main.auth_password`, or calls the ubus object's `set_password`; `check` warns of a hash left in the main section, which is ignored. A hash without a user is no basic auth now, rather than an invalid configuration, and `validate` no longer answers `AUTH_NEEDS_USER`. LuCI's ACL grants `password` and `set_password`, and no longer `hash_password`. See [How to serve HTTPS with basic auth](https-basic-auth.md).
- **textfile's `directory` must be under `/var`, `/tmp` or `/etc/prometheus-exporter`.** The service makes and mounts no other: move one elsewhere, as under `/srv`, before upgrading, or the configuration is refused (`OWNED_DIRECTORY`).
- **`memory_limit` takes 0, or 8 MB and more.** 1 to 7 passed `check`, and uhttpd crash-looped; they are refused now (`ZERO_OR_MIN`).
- **hostapd_stations labels each station's series by `vif` and `station` alone.** `ssid`, `bssid`, `encryption`, `frequency` and `channel` are on the new `hostapd_station_info` alone, one series per station. A query that selected by them joins it: `hostapd_station_signal_dbm * on (vif, station) group_left (ssid) hostapd_station_info`.
- **netstat exports node_exporter's default fields only**, some 40 series where it wrote about 400. Its new option `fields`, a regular expression of `<Section>_<Field>`, takes others; `.*` exports every one, as 0.2.0 did:

    ```sh
    uci set prometheus-exporter.netstat=collector
    uci set prometheus-exporter.netstat.fields='.*'
    uci commit prometheus-exporter
    ```

- **nat_traffic labels an IPv6 address compressed**, `2001:db8:0:1::e157` where it had `2001:0db8:0000:0001:0000:0000:0000:e157`, as every other collector labels it. A query or recording rule that matched the long form matches the short one now; the series start anew at the upgrade.
- **A collector passes its labels as an object, null, or what `out.labels()` made.** A string of labels spliced by hand, which was written as it was, now fails the collector with `EXPOSITION_INVALID`, as a label value that is not UTF-8 and two label names that are one once sanitized do. Every collector of the exporter's packages does already; check one of another package with `prometheus-exporter collector check`.
- **The loader refuses a collector that calls `system()` or `include()`**, as it refuses `require`: run programs through `deps.exec`. See [Collector contract](../reference/collector-contract.md#what-a-collector-may-import).

These change what 0.2.0 did without breaking a configuration:

- **The jail has the ubus socket only while an enabled collector needs ubus.** A collector of another package whose programs call ubus, without `ubus` in its `meta.needs`, finds no ubus when every collector that needs it is disabled: declare it.
- **uhttpd runs 3 requests at once over 10 connections at most**, where it took its defaults of 3 and 100: a client past them waits. One or two Prometheus servers need no more; see [HTTP endpoint](../reference/http.md#connections).

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
