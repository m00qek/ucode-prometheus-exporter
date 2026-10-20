# How to Upgrade the Exporter

Upgrade every exporter package together. Each collector package, each group, the command line's package and the LuCI app depends on the base package of exactly the same version.

## Before you upgrade

Read what the new version changes. Before 0.3.0, a minor version could rename metrics or options. From 0.3.0 on, only a major version does: see [About versions](../explanation/versions.md#what-10-keeps). A renamed metric breaks every query and dashboard that uses the old name.

---

## From the feed

If you added the exporter's feed, as [How to install the exporter](install.md#1-add-the-feed) does, run:

```sh
apk update
apk upgrade
```

## From `.apk` files

1. Copy the new version of every package you have installed to the device's `/tmp`.
2. Set `version` to the new version, as the files' names end, and add them all in one command:

```sh
version=0.2.0-r1
apk add --allow-untrusted /tmp/ucode-prometheus-exporter-*$version.apk /tmp/luci-app-prometheus-exporter-$version.apk
```

Adding the base package alone fails, because the installed collectors still want the old version.

If the new version adds a dependency, apk takes it from the feeds the device has. For example, `ucode-docopt`, which the command line's package depends on, comes from the exporter's feed.

## From 0.2.1 to 0.3.0

0.3.0 is the first release candidate for 1.0: 1.0 keeps the names and labels of its metrics. The changes below break something that worked in 0.2.1. The [CHANGELOG](https://github.com/m00qek/ucode-prometheus-exporter/blob/main/CHANGELOG.md) marks each one **BREAKING**.

- **snmp6 exports 13 fields of each device by default**, where 0.2.1 wrote every one, some 70. By default it now keeps only these `node_snmp6_*_total` fields of each device: `Ip6_InOctets`, `Ip6_OutOctets`, `Ip6_OutForwDatagrams`, `Ip6_InDiscards`, `Ip6_OutDiscards`, `Ip6_InNoRoutes`, `Ip6_OutNoRoutes`, `Ip6_InHdrErrors`, `Ip6_InAddrErrors`, `Ip6_InTooBigErrors`, `Icmp6_InMsgs`, `Icmp6_OutMsgs` and `Icmp6_InErrors`. It also drops `node_snmp6_ifindex`, since netclass's `node_network_iface_id` has the same index. To export other fields, set the new option `fields`, a regular expression of `<Protocol>_<Field>`. `.*` exports every field, as 0.2.1 did:

    ```sh
    uci set prometheus-exporter.snmp6=collector
    uci set prometheus-exporter.snmp6.fields='.*'
    uci commit prometheus-exporter
    ```

- **nat_traffic writes one series per host on this side of the router, labeled `host`.** 0.2.1 wrote one series per pair of addresses, labeled `src` and `dst`. So `node_nat_traffic_bytes{src,dst}` is now `node_nat_traffic_bytes{host}`.

    `host` is the end of the connection that is on this side of the router, a LAN host or the router itself, as the routes say:

    - For a LAN host's connection out, it is the source, as `src` was.
    - For a port-forwarded connection, it is the LAN host the connection reaches. `src` was the remote address.
    - For a connection from the internet to the router, it is the router's WAN address. For ICMPv6 to a LAN host, it is the LAN host. In both cases `src` was the sender.

    Connections with neither end on this side share one series, `host="other"`. So do the hosts beyond the 2048 with the most bytes.

    A query by `src` becomes a query by `host`, as `node_nat_traffic_bytes{host="192.168.1.10"}`. A query by `dst` needs the pairs. The new option `peers` brings them back, labeled `host` and `peer`. It writes as many series as 0.2.1 did, with new ones for every connection, and a Prometheus server keeps each for hours. Turn it on only for a short look:

    ```sh
    uci set prometheus-exporter.nat_traffic=collector
    uci set prometheus-exporter.nat_traffic.peers=1
    uci commit prometheus-exporter
    ```

- **`cert` and `key` must be under `/etc/ssl`, `/etc/acme` or `/etc/prometheus-exporter`, or be uhttpd's own `/etc/uhttpd.*`.** Each must be a regular file of at most 64 KiB. If it is a link, the link must stay inside those directories. Root copies these files for the service's group, and copies no others. The service refuses a configuration that names another path (`TLS_PATH`), such as `/etc/prometheus-exporter.crt`, which this guide's HTTPS how-to used. It does not start until you move the files, as `check` says:

    ```sh
    mkdir -p /etc/prometheus-exporter
    mv /etc/prometheus-exporter.crt /etc/prometheus-exporter/tls.crt
    mv /etc/prometheus-exporter.key /etc/prometheus-exporter/tls.key
    uci set prometheus-exporter.main.cert=/etc/prometheus-exporter/tls.crt
    uci set prometheus-exporter.main.key=/etc/prometheus-exporter/tls.key
    uci commit prometheus-exporter
    ```

    The configuration import from a feed exporter leaves out such a `cert` or `key`, and logs it: `option cert: expected a file under /etc/ssl, ...; left at the default`. See [How to serve HTTPS with basic auth](https-basic-auth.md).
- **The jail no longer runs as root.** uhttpd runs in it as the user and group `prometheus-exporter`, which the upgrade creates. The upgrade restarts a running service. On start, the service grants that user what its enabled collectors declare. You need to do nothing:
    - The state directory belongs to the user, and starts empty, as at every restart.
    - The service writes basic auth's file again, readable by the user's group.
    - The service copies the TLS key and certificate for the user's group. The original files stay as they were, the key readable by root alone.
    - The service opens the configs its collectors read to the user's group, read-only.

    See [The jail](../reference/jail.md#the-services-user).
- **textfile's files must be readable by the service's user.** If a script writes a `*.prom` file that only root can read (mode 0600, as `mktemp` makes it), textfile skips the file and logs it. Run `chmod 0644` on the file before renaming it into place. See [How to publish metrics from scripts](textfile.md).
- **The `prometheus-exporter` command is now its own package, `ucode-prometheus-exporter-cli`.** The base package no longer installs `/usr/bin/prometheus-exporter`, and no longer depends on `ucode-docopt`. So `apk upgrade` leaves the device without the command. A script or cron job that runs it fails until you install the package. That includes `prometheus-exporter scrape`, which [How to push metrics](push-metrics.md) uses, and `hash-password`:

    ```sh
    apk add ucode-prometheus-exporter-cli
    ```

    The service does not need the command:
    - `service prometheus-exporter check`, and the check that start and reload run, are the base package's `/usr/libexec/prometheus-exporter/check.uc`.
    - LuCI and the ubus object set basic auth's password (`set_password`).

    Without the command's package, apk also removes `ucode-docopt`, which nothing else of the exporter needs. See [The `prometheus-exporter` command](../reference/command.md).
- **A collector of another package that calls ubus must declare its calls** in `meta.ubus`, as `ubus: { dnsmasq: [ 'metrics' ], rc: [ 'list' ] }` (`rc list` for the API's `services`). The loader refuses a collector that needs ubus without them, and a call the collector does not declare fails with `UBUS_NOT_ALLOWED`. A collector must also declare when it reads a root-only file of `/proc` (`proc_files`), needs a capability (`capabilities`), or connects to a socket of another service's group (`groups`). Every collector of the exporter's packages does this. To check a collector of another package, run `prometheus-exporter collector check` (from `ucode-prometheus-exporter-cli`). See [Collector interface](../reference/collector-interface.md#meta).
- **The collector API is `prometheus.exporter`, and collectors are in `/usr/share/ucode/prometheus/collectors/`.** The exporter's modules moved from `/usr/share/ucode/prometheus_exporter/` to `/usr/share/ucode/prometheus/`:
    - The collector API, `prometheus_exporter.api`, is now `prometheus.exporter`, with the same names.
    - The exporter's own modules and the devkit's are `prometheus.exporter.<module>`.
    - The collectors are `prometheus.collectors.<module>`.

    The upgrade removes every file the exporter's packages installed under the old directory. The exporter reads its collectors from the new directory alone. A collector of another package stays where its package installed it, in `/usr/share/ucode/prometheus_exporter/collectors/`. The exporter does not load or list it until you rebuild its package for 0.3.0 and install it again.

    In the collector's source, rename the module, its tests, its utest config and its Makefile, and move the module to `src/prometheus/collectors/`:

    ```sh
    grep -rlZ --exclude-dir=.git prometheus_exporter . | xargs -0 sed -i -e 's/prometheus_exporter\.api/prometheus.exporter/g' -e 's#prometheus_exporter\([./]\)collectors#prometheus\1collectors#g' -e 's#prometheus_exporter\([./]\)#prometheus\1exporter\1#g' --
    mkdir -p src/prometheus && git mv src/prometheus_exporter/collectors src/prometheus/
    ```

    The metric names, `ucode_prometheus_exporter_*`, do not change. See [How to write a collector in your own package](collector-package.md).
- **A collector's top level may only declare.** The top level runs again in uhttpd's own process each time the service starts, and nothing can stop it there. So, both there and in the child process that first loads the collector, the exporter refuses a top level that calls any of these, before the call runs:
    - `sleep`, `exit`, `print`, `printf`, `warn`, `trace`, `require`, `include`, `loadfile`, `loadstring`, `render` or `signal`
    - the collector API's `exposition` functions

    The exporter then leaves the collector out and logs `COLLECTOR_IMPURE` at `err`. Every collector of the exporter's packages only declares. For a collector of another package, move the work its top level does into `collect()`. Check it with `prometheus-exporter collector check` (from `ucode-prometheus-exporter-cli`), which now also looks for statements and calls past the declarations. See [Collector interface](../reference/collector-interface.md#the-top-level).


These changes differ from 0.2.1 without breaking a query or a configuration:

- **ethtool runs ethtool three times per device**: `-S`, `-i` and with no option. It ran it once before. The two new runs feed node_exporter's `node_ethtool_info` and link families. The three runs share the seconds of the collector's `timeout`, which defaults to the main section's `exec_timeout`, 5. On a slow router with many ports, if ethtool fails with `COMMAND_TIMEOUT`, give it more time. See [How to give programs more time](exec-timeout.md).
- **The filesystem package installs an rpcd plugin**, the ubus object `prometheus-exporter.filesystem`. The plugin answers each mount's type, read-only flag, sizes and inodes. The package reloads rpcd when you install or remove it. Only the collector calls the plugin. The service's user may no longer call rpcd's `file read` or luci's `getMountPoints`. Where rpcd has not loaded the plugin, the collector fails and says so, until you run `/etc/init.d/rpcd reload`.
- **wifi, hostapd_stations, timesync and wireguard's `peer_names` ask the service's own ubus object, `prometheus-exporter`.** They ask it for:
    - the radios, without their keys (`wireless`)
    - whether ntpd and chronyd run (`time_daemons`)
    - the peers' descriptions (`wireguard_peers`)

    The service's user may no longer call netifd's `network.wireless status`, procd's `service list` or rpcd's `uci get`. Those answer every Wi-Fi key, every service's command line and any config. A collector of another package may still call one of them, by declaring it, while that collector is enabled. See [About the security model](../explanation/security.md#what-the-services-user-reaches-over-ubus).
- **`OpenWrtWifiRadioDown` fires for a radio that is enabled and not up.** It uses wifi's new `node_wifi_radio_up` and `node_wifi_radio_disabled`. Before, it fired for any radio without a network, including one disabled on purpose. If you copied the old rule, copy the new one from `monitoring/prometheus/router.rules.yml`.
- **Two new collectors, each in its own package, which no group installs**: `pressure` (pressure stall information) and `interrupts`. `pressure` needs a kernel with `CONFIG_PSI`, which OpenWrt's kernels leave off. To use one, install its package: `apk add ucode-prometheus-exporter-pressure`. See [How to choose collectors](choose-collectors.md#install-collectors).
- **LuCI changes basic auth's password with its own button, Change password…**, on the HTTPS & login tab. 0.2.1 had a field that Save handed on. The password still applies at once, separately from Save & Apply, and the dialog asks for it twice. Once you empty the user, **Remove password** removes the saved password. The app's ACL is unchanged. See [How to use the LuCI app](luci.md#change-basic-auths-password).
- **A collector that is refused something it needs fails with `PERMISSION_DENIED`**, and says what grants it. Before, it would have reported nothing to observe. A reload grants again what the service granted at start and has since been taken away.
- **The exporter refuses, where it is written, text that would make Prometheus refuse a whole scrape**:
    - a label named `__name__`, or any other label name that starts with `__`
    - a NUL byte in a label value, a HELP text or a family's name

    textfile leaves out a `*.prom` file that has one and logs `EXPOSITION_INVALID`. A collector that writes one fails with that code. 0.2.1 served such text, and Prometheus then refused every collector's samples.
- **dhcp_leases and thermal each write one more family**:
    - `node_openwrt_dhcp_pool_size{interface}`, the size of each interface's DHCPv4 pool
    - `node_thermal_zone_critical_celsius{zone,type}`, each zone's critical trip point, which the bundled alerts use

    See [Metrics](../reference/metrics.md).
- **`check` shows the jail's user, its capabilities and its ubus ACL.** The `jail` of the ubus object's `describe` lists each collector's calls, capabilities, groups and proc files.

## From 0.2.0 to 0.2.1

The changes below break something that worked in 0.2.0. The [CHANGELOG](https://github.com/m00qek/ucode-prometheus-exporter/blob/main/CHANGELOG.md) marks each one **BREAKING**.

- **Basic auth's hash has its own config.** The exporter reads `auth_password` from `/etc/config/prometheus-exporter-auth`, which the package installs with mode 0600. It no longer reads it from the main section of `/etc/config/prometheus-exporter`, which LuCI's ACL lets a login read.
    - The upgrade moves a hash it finds in the main section, and logs `auth_password moved from /etc/config/prometheus-exporter to /etc/config/prometheus-exporter-auth`.
    - A script that sets the hash sets `prometheus-exporter-auth.main.auth_password`, or calls the ubus object's `set_password`.
    - `check` warns about a hash left in the main section. The exporter ignores it.
    - A hash without a user now means no basic auth, rather than an invalid configuration. `validate` no longer answers `AUTH_NEEDS_USER`.
    - LuCI's ACL grants `password` and `set_password`, and no longer `hash_password`.

    See [How to serve HTTPS with basic auth](https-basic-auth.md).
- **textfile's `directory` must be under `/var`, `/tmp` or `/etc/prometheus-exporter`.** The service creates and mounts no other directory. If yours is elsewhere, such as under `/srv`, move it before upgrading, or the service refuses the configuration (`OWNED_DIRECTORY`).
- **`memory_limit` takes 0, or 8 MB and more.** Values 1 to 7 passed `check`, and uhttpd then crash-looped. The service now refuses them (`ZERO_OR_MIN`).
- **hostapd_stations labels each station's series by `vif` and `station` alone.** `ssid`, `bssid`, `encryption`, `frequency` and `channel` are now only on the new `hostapd_station_info`, one series per station. A query that selected by them now joins it: `hostapd_station_signal_dbm * on (vif, station) group_left (ssid) hostapd_station_info`.
- **netstat exports only node_exporter's default fields**, some 40 series where it wrote about 400. To export others, set its new option `fields`, a regular expression of `<Section>_<Field>`. `.*` exports every field, as 0.2.0 did:

    ```sh
    uci set prometheus-exporter.netstat=collector
    uci set prometheus-exporter.netstat.fields='.*'
    uci commit prometheus-exporter
    ```

- **nat_traffic writes IPv6 addresses compressed**: `2001:db8:0:1::e157`, where it wrote `2001:0db8:0000:0001:0000:0000:0000:e157`. Every other collector already labels them this way. A query or recording rule that matched the long form must match the short one now. The series start anew at the upgrade.
- **A collector passes its labels as an object, null, or what `out.labels()` made.** A string of labels spliced by hand was written as it was. Now it fails the collector with `EXPOSITION_INVALID`. So does a label value that is not UTF-8, and two label names that become the same once sanitized. Every collector of the exporter's packages already complies. To check a collector of another package, run `prometheus-exporter collector check`.
- **The loader refuses a collector that calls `system()` or `include()`**, as it already refused `require`. Run programs through `deps.exec`. See [Collector contract](../reference/collector-contract.md#what-a-collector-may-import).

These changes differ from 0.2.0 without breaking a configuration:

- **The jail has the ubus socket only while an enabled collector needs ubus.** Take a collector of another package whose programs call ubus but whose `meta.needs` lacks `ubus`. When every collector that needs ubus is disabled, it finds no ubus. Declare `ubus` in its `meta.needs`.
- **uhttpd runs at most 3 requests at once, over at most 10 connections.** Before, it used its defaults of 3 and 100. A client beyond those limits waits. One or two Prometheus servers need no more. See [HTTP endpoint](../reference/http.md#connections).

## From 0.1 to 0.2

0.2.0 changes what 0.1 did in these ways:

- **The command line takes subcommands.** `prometheus-exporter [COLLECTOR...]` is now `prometheus-exporter scrape [COLLECTOR...]`, and `prometheus-exporter -l` is now `prometheus-exporter collector list`. A script or cron job that runs the command needs the new form: see [The prometheus-exporter command](../reference/command.md).
- **wifi_stations is gone.** It wrote the same families as wifi's option `stations`, so each station was exported twice. Before the upgrade, remove it with `apk del ucode-prometheus-exporter-wifi_stations`. Then install `ucode-prometheus-exporter-wifi` if it is not there: its `stations` option is on by default.
- **A collector's package no longer installs what it watches.** The packages of the mwan3, chrony, modemmanager, ubnt-manager and wireguard collectors depended on mwan3, chrony, modemmanager, ubnt-manager and rpcd-mod-wireguard. So installing the mwan3 collector installed and started mwan3, which changes the routing, and the chrony collector installed a second NTP daemon. Now they depend on none of these. Where the watched program is absent, the collector has nothing to observe. The upgrade removes nothing, because apk keeps what was installed. If you installed one only for its collector, remove it (`apk del mwan3`, for example).
- **A collector imports the collector API alone.** A collector module imports `prometheus_exporter.api`, which exports `Result`, `errors`, `services`, `proc` and `exposition`, and no other module. The exporter leaves out a collector that imports `prometheus_exporter.result`, `fs` or any other module, and logs it at `err`. Every collector of the exporter's packages already complies. If a collector of another package was written for 0.1, change it to take the same names from the API: `import { Result, errors, proc } from 'prometheus_exporter.api';`, and `proc.first_line(...)` for `first_line(...)`. Check it with `prometheus-exporter collector check`. See [Collector contract](../reference/collector-contract.md#what-a-collector-may-import).
- **A collector's options need a title.** Each option of `meta.options` declares `title`, the short, sentence-case label that LuCI's Edit dialog shows: `device_exclude: { default: '...', title: 'Excluded devices', help: '...' }`. The exporter leaves out a collector with an option that has no title, and logs it at `err`. Every collector of the exporter's packages has titles. See [Collector interface](../reference/collector-interface.md#options).
- **The ubus object's `validate` answers codes.** Each refused value used to be an English sentence. Now it is an object, `{ code, ...arguments, message }`, whose `message` is the sentence, as `{ "code": "RANGE", "min": 1, "max": 65535, "value": 0, "message": "expected an integer from 1 to 65535, got 0" }`. A script that reads the reply reads `message`, or the code: see [ubus object](../reference/ubus.md#validate). `check`, the log and the command line say what they said before.
- **A collector that breaks the collector contract fails alone.** The exporter stops it at its budget, at its `max_samples`, or when it writes another collector's family. See [Collector contract](../reference/collector-contract.md).

## Check the result

```sh
wget -qO- http://127.0.0.1:9100/metrics | grep build_info
service prometheus-exporter check
```

`ucode_prometheus_exporter_build_info{version="..."}` shows the new version. The upgrade restarts a running service and leaves `/etc/config/prometheus-exporter` as you had it. If you changed that file, apk may put the new version's file beside it, as `/etc/config/prometheus-exporter.apk-new`. Compare the two, take what you want, then remove the `.apk-new` file.
