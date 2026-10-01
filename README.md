# ucode-prometheus-exporter

Metrics of OpenWrt for Prometheus, written in ucode and served by uhttpd at `/metrics` on port 9100. A rewrite of the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`, with the Lua exporter's collectors ported alongside the ucode one's. It replaces them, under names of its own: the package `ucode-prometheus-exporter`, the service, command and config `prometheus-exporter`.

The metric names are not those packages'. They are the Prometheus [node_exporter](https://github.com/prometheus/node_exporter)'s where it has the metric, so its dashboards work, and elsewhere follow the [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/) (base units, `_total` on counters only, `_info` for labels); a service keeps its own prefix, and the names of its standalone exporter where they follow the conventions. [docs/metrics.md](docs/metrics.md) lists every name that changed, and why.

It targets OpenWrt 25.12 and uses no ucode API newer than that release's.

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Using it

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-openwrt
wget -qO- http://127.0.0.1:9100/metrics                      # every installed collector
wget -qO- 'http://127.0.0.1:9100/metrics?collect[]=loadavg' # some of them (also exclude[]=)
prometheus-exporter -l                                      # list the collectors
prometheus-exporter loadavg                                 # a scrape, on the command line
```

The base package has the collectors every device can use (cpu, meminfo, netdev, netclass, loadavg, conntrack and more); each other collector is its own `ucode-prometheus-exporter-<name>` package. Groups install several at once:

| | |
|---|---|
| `-network` | ethtool, nat_traffic, netstat, nft-counters, snmp6 |
| `-wireless` | wifi, hostapd_stations, hostapd_ubus_stations |
| `-hardware` | hwmon, thermal, filesystem |
| `-full` | the three above, and dhcp_leases, dnsmasq, openwrt, textfile, uci_dhcp_host, wireguard |

The collectors of particular hardware or services (ltq-dsl, realtek-poe, bmx7, mwan3, modemmanager, ubnt-manager, dawn, unbound) and wifi_stations, which repeats wifi's station metrics, are in no group.

Every collector, with its title and package (`ucode-prometheus-exporter-…`):

| | | |
|---|---|---|
| `bmx7` | bmx7 mesh | `-bmx7` |
| `conntrack` | Connection tracking | base |
| `cpu` | CPU | base |
| `dawn` | DAWN band steering | `-dawn` |
| `dhcp_leases` | DHCP leases | `-dhcp_leases`; in `-full` |
| `dnsmasq` | dnsmasq DNS and DHCP | `-dnsmasq`; in `-full` |
| `entropy` | Kernel entropy | base |
| `ethtool` | Network driver statistics | `-ethtool`; in `-network`, `-full` |
| `filefd` | File descriptors | base |
| `filesystem` | Filesystems | `-filesystem`; in `-hardware`, `-full` |
| `hostapd_stations` | hostapd stations | `-hostapd_stations`; in `-wireless`, `-full` |
| `hostapd_ubus_stations` | hostapd station capabilities | `-hostapd_ubus_stations`; in `-wireless`, `-full` |
| `hwmon` | Hardware sensors | `-hwmon`; in `-hardware`, `-full` |
| `loadavg` | Load average | base |
| `ltq-dsl` | Lantiq DSL line | `-ltq-dsl` |
| `meminfo` | Memory | base |
| `modemmanager` | Cellular modems | `-modemmanager` |
| `mwan3` | mwan3 multi-WAN | `-mwan3` |
| `nat_traffic` | Traffic per address pair | `-nat_traffic`; in `-network`, `-full` |
| `netclass` | Network device properties | base |
| `netdev` | Network device statistics | base |
| `netstat` | Protocol statistics | `-netstat`; in `-network`, `-full` |
| `nft-counters` | nftables counters | `-nft-counters`; in `-network`, `-full` |
| `openwrt_interfaces` | OpenWrt interfaces | base |
| `openwrt` | OpenWrt release and board | `-openwrt`; in `-full` |
| `realtek-poe` | Realtek PoE | `-realtek-poe` |
| `selinux` | SELinux | base |
| `snmp6` | IPv6 statistics per device | `-snmp6`; in `-network`, `-full` |
| `softnet` | Network softirq statistics | base |
| `textfile` | Text files | `-textfile`; in `-full` |
| `thermal` | Thermal zones | `-thermal`; in `-hardware`, `-full` |
| `time` | System time | base |
| `ubnt-manager` | Ubiquiti airOS radios | `-ubnt-manager` |
| `uci_dhcp_host` | Static DHCP hosts | `-uci_dhcp_host`; in `-full` |
| `uname` | Kernel and host names | base |
| `unbound` | Unbound DNS resolver | `-unbound` |
| `vmstat` | Virtual memory statistics | base |
| `wifi_stations` | Wi-Fi stations | `-wifi_stations` |
| `wifi` | Wi-Fi | `-wifi`; in `-wireless`, `-full` |
| `wireguard` | WireGuard | `-wireguard`; in `-full` |

Neither upstream exporter had these: softnet and vmstat (node_exporter's), conntrack's statistics and openwrt_interfaces (netifd's logical interfaces: up, uptime, devices, address counts) in the base package, and dhcp_leases (dnsmasq's and odhcpd's active leases).

## Configuration

`/etc/config/prometheus-exporter` is optional: every option has a default.

```
config prometheus-exporter 'main'
	option enabled '1'                 # 0: the service does not run
	option listen_interface 'loopback' # a logical interface, or * for every address
	option listen_port '9100'
	option http_keepalive '70'         # seconds; 0 for none
	option omit_zero_values '0'        # 1: leave out counters that are 0
	#option cert '/etc/uhttpd.crt'     # both, for HTTPS
	#option key '/etc/uhttpd.key'

config collector 'textfile'          # named after the module: ltq_dsl for ltq-dsl
	option enabled '1'                 # 0: not served; naming it in a query is a 400
	option directory '/var/prometheus'
```

A collector without a section is enabled, with its defaults. These take options (`check` prints each with its help):

| | | |
|---|---|---|
| `dhcp_leases` | `leases` | `0`; 1 adds a series per lease (address, MAC, hostname, expiry) |
| `textfile` | `directory` | `/var/prometheus`; an absolute path, where the `*.prom` files are |
| `unbound` | `socket` | `/run/unbound.ctl`; an absolute path, unbound's control socket, in a directory of its own (see the jail) |
| `vmstat` | `fields` | `^(oom_kill\|pgpg\|pswp\|pg.*fault).*`; a regex of the /proc/vmstat fields |
| `wifi` | `stations` | `1`; 0 leaves out the per-station metrics |

A config change applies on `reload_config` (LuCI does it), or `service prometheus-exporter reload`.

## The service

| | |
|---|---|
| `service prometheus-exporter check` | checks the config, lists each collector (title, section, options with their help, needs, what the jail gives it) and runs a scrape, saying what fails and why |
| `… status` | running, and where it listens and how many collectors it serves; or disabled |
| `… reload` | starts again with the new config; an invalid one keeps the running exporter, and the log says why |

Start and reload refuse an invalid config. Installing or removing a collector package reloads the service.

uhttpd runs in procd's jail, and a collector gets what it declares: procfs, sysfs, ubus and the log for all, then the configs it reads (`/etc/config/dhcp` for uci_dhcp_host), the files and directories it reads (textfile's directory, dhcp_leases' lease files, bmx7's status), and the programs it runs with their libraries (`/bin/sh` and `nft` for nft-counters). Nothing else of `/etc/config` is there. What the jail cannot give is a warning in `check`:

- A path that is not there when the service starts (textfile's directory, say) is mounted at the next start after it is.
- ujail cannot mount a socket, so a collector gets the socket's directory. That is never one every service shares, such as `/run`: unbound's control socket needs a directory of its own, there when the exporter starts (`control-interface:` in unbound's config, and the `socket` option here).

## Developing

Everything runs in OpenWrt's own images (Docker), on the release in `OPENWRT_VERSION` (25.12.5 by default; CI also runs 25.12.0).

| | |
|---|---|
| `make test` | unit and integration tests (utest); `unit`, `integration`, `watch`; `FILTER=`, `VERBOSE=1`, `MODULES=` |
| `make lint` | loads every module on 25.12's ucode, so a function it lacks fails here |
| `make package` | the apks, built with the OpenWrt SDK, into `bin/` |
| `make package-check` | installs them offline and scrapes a real uhttpd on loopback |
| `make e2e` | boots OpenWrt (procd, ubusd, netifd) in a privileged container and checks the service, in its jail, as packages come and go and its config changes |
| `make fixtures HOST= NAME=` | reads `test/fixtures/SOURCES` from a device over ssh into `test/fixtures/NAME/` |

Layout: `src/prometheus_exporter/` is the ucode library (installed to `/usr/share/ucode/prometheus_exporter/`), `files/` the handler, command, init script and config, `openwrt/` the package Makefile, `test/unit/` mirrors `src/`.

## Writing a collector

A collector is a module in `src/prometheus_exporter/collectors/<module>.uc`:

```js
'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { first_line, fields } from 'prometheus_exporter.proc';

export const meta = {
	name: 'loadavg',                          // ?collect[]=, the subpackage suffix; may hold '-'
	title: 'Load average',                    // a label of up to 40 characters, for lists and forms
	help: 'Load averages from /proc/loadavg.',
	needs: [ 'fs' ],                          // all it gets in `deps`
	// configs: [ 'dhcp' ],                   // with 'uci': the configs it may read
	// commands: [ 'nft' ],                   // with 'exec': the programs it may run
	// options: {                             // not enabled, the core's
	//	directory: { default: '/var/prometheus', datatype: 'directory', help: 'The directory of the *.prom files.' },
	// },
	// paths: [ '{directory}' ],              // what it reads outside /proc and /sys; see below
};

export function collect(deps, out, options) {
	let x = fields(first_line(deps.fs, '/proc/loadavg'));
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, '/proc/loadavg');

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	return Result.ok();
};
```

- `needs` are `fs` (`readfile open lsdir glob stat realpath`), `ubus` (`call`, `list`, as Results), `uci` (`deps.uci.<config>` for each of `configs`, read-only: `loaded get get_all sections foreach`, committed configuration only), `rtnl` and `nl80211` (`request` as Results, `const`), `socket` (`unix_request(path, message, timeout_ms)`, a Unix socket's whole reply as a Result), `exec` (`run(argv)` as a Result, for `commands` only; a failure's `data.status` is the exit status), `time` (`now()`) and `log` (`log(msg)`, for what a collector that succeeds still has to say). Only `prometheus_exporter.deps` touches the system.
- The exporter runs in procd's jail, which mounts what the installed and enabled collectors declare and nothing else: `/etc/config/<c>` for each of `configs`, `/bin/sh` and each of `commands` (with its libraries), and `paths`. A path may name a string option as `{option}` (textfile's `'{directory}'`), or be a function `(options, uci) => [ paths ]` for what a config decides (dhcp_leases' lease files). A socket is declared by its directory, as ujail cannot mount a socket; a shell script needs what it sources and runs (ubnt-manager).
- An option's `default` sets its type (boolean, integer or string), `help` says what it does, and `datatype`, optional, narrows its values with one of LuCI's names that the core checks: `uinteger`, `range(min,max)`, `directory` and `file` (an absolute path; it need not exist), and `regex` (one ucode compiles), which LuCI lacks. `collect` gets the options typed; a value that does not fit fails the collector with CONFIG_INVALID.
- `out.gauge|counter|untyped(name, help)` returns `(labels, value)`, which chains; `out.parse(text)` adds exposition text. What a collector records is kept even when it then fails.
- `collect` returns a Result: `ok` is `node_scrape_collector_success 1`; `err` is 0 and one log line.
- An absent kernel feature is nothing to report, for any collector: where nf_conntrack is not loaded (an AP without a firewall), conntrack and nat_traffic return `ok` with no samples. A missing service or program (no unbound control socket, no `ethtool`) is an `err`.

Each collector needs a test in `test/unit/prometheus_exporter/collectors/`, and a line in the package Makefile that depends on what its `needs` and `commands` call for; `test/integration/collectors_test.uc` holds every collector to both.

## LuCI app

`luci-app-prometheus-exporter` adds two pages, and pins the exporter's release:

- **Services → Prometheus exporter**: the main section (enabled, listen interface or every address, port, keepalive, TLS files, `omit_zero_values`) and a row per installed collector, with its switch, its options by type and what it is: in the base package or a removable one, and the configs it reads. A collector's `config collector` section holds only what differs from the defaults: it is added when a value first differs and removed once all are back. Values are checked as they are typed and again before Save, as the exporter reads them; nothing it would refuse is saved.
- **Status → Prometheus exporter**: whether the service is enabled and runs, where it serves `/metrics`, and each collector's result, duration and error in a scrape run on the router (outside the jail) when the page opens or on Refresh, with what the jail mounts for it.

Both call the `prometheus-exporter` ubus object, an rpcd ucode plugin (`files/usr/share/rpcd/ucode/`) over `src/prometheus_exporter/luci/rpc.uc`, which reads with the exporter's own modules and writes nothing; the pages save through uci. Its ACL grants the exporter's config and the plugin's methods, nothing else.

| | |
|---|---|
| `collectors {}` | `{ collectors: [ { name, id, title, help, enabled, package, base, options: [ { name, type, default, help, datatype, value, set, error } ], needs, configs, commands, jail: { paths, commands, mounts, problems, missing }, error } ], skipped }` |
| `validate { main?, collectors? }` | `{ ok, errors: { main: { <option>: message }, collectors: { <module>: { <option>: message } } } }` for values as uci holds them |
| `status {}` | `{ service: { enabled, boot, running, error }, listen: [ url ], collectors: [ { name, id, title, enabled, success, duration, error, mounts } ] }` |

`status` scrapes in a process of its own (`/usr/libexec/prometheus-exporter/luci-status.uc`) and replies when it is done, so rpcd answers other calls meanwhile, the collectors' calls to objects rpcd itself serves (`wireguard`, `luci`) among them.

| | |
|---|---|
| `make browser` | the Playwright tests in `test/browser/` against LuCI in a container: the built packages, the plugin in a real rpcd, real collectors and a stand-in for procd (`devenv/services/luci/`); `FILTER=`. Screenshots in `bin/browser/screenshots/` |
| `make pot` | `luci/po/templates/prometheus-exporter.pot`, with openwrt/luci's scanner; `make lint` fails while it is out of date |

`make lint` also parses the views (as the function bodies LuCI compiles them into) and the JSON, and fails on LuCI code that could turn data into markup (`devenv/scripts/luci-dom-lint.sh`); `make package-check` installs the app, checks its files and runs its plugin in rpcd.

## Credits

A rewrite of two packages of OpenWrt's feed, both Apache-2.0: [`prometheus-node-exporter-ucode`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-ucode), by Andre Heider (its maintainer) and contributors, and [`prometheus-node-exporter-lua`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-lua), by Jeff Schornick, Kevin Lyda, Christian Simon, Etienne Champetier (its maintainer) and contributors. Metric names and help texts follow the Prometheus [node_exporter](https://github.com/prometheus/node_exporter) and, for unbound and WireGuard, [unbound_exporter](https://github.com/letsencrypt/unbound_exporter) and [prometheus_wireguard_exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter); see [docs/metrics.md](docs/metrics.md). Tests run on [utest](https://github.com/m00qek/utest). [NOTICE](NOTICE) credits each collector's upstream authors.
