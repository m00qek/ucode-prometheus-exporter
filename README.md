# prometheus-node-exporter-ucode

Node metrics for Prometheus from OpenWrt, written in ucode and served by uhttpd at `/metrics`. A rewrite of OpenWrt's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`: the same package name, port (9101) and config file, with the Lua exporter's collectors ported alongside.

The metric names are not those packages'. They are the Prometheus [node_exporter](https://github.com/prometheus/node_exporter)'s where it has the metric, so its dashboards work, and elsewhere follow the [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/) (base units, `_total` on counters only, `_info` for labels); a service keeps its own prefix, and the names of its standalone exporter where they follow the conventions. [docs/metrics.md](docs/metrics.md) lists every name that changed, and why.

It targets OpenWrt 25.12 and uses no ucode API newer than that release's.

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Using it

```sh
apk add prometheus-node-exporter-ucode prometheus-node-exporter-ucode-openwrt
wget -qO- http://127.0.0.1:9101/metrics                      # every installed collector
wget -qO- 'http://127.0.0.1:9101/metrics?collect[]=loadavg' # some of them (also exclude[]=)
prometheus-node-exporter-ucode -l                           # list the collectors
prometheus-node-exporter-ucode loadavg                      # a scrape, on the command line
```

The base package has the collectors every device can use (cpu, meminfo, netdev, netclass, loadavg, conntrack and more); each other collector is its own `prometheus-node-exporter-ucode-<name>` package. Groups install several at once:

| | |
|---|---|
| `-network` | ethtool, nat_traffic, netstat, nft-counters, snmp6 |
| `-wireless` | wifi, hostapd_stations, hostapd_ubus_stations |
| `-hardware` | hwmon, thermal, filesystem |
| `-full` | the three above, and dhcp_leases, dnsmasq, openwrt, textfile, uci_dhcp_host, wireguard |

The collectors of particular hardware or services (ltq-dsl, realtek-poe, bmx7, mwan3, modemmanager, ubnt-manager, dawn, unbound) and wifi_stations, which repeats wifi's station metrics, are in no group.

Neither upstream exporter had these: softnet and vmstat (node_exporter's), conntrack's statistics and openwrt_interfaces (netifd's logical interfaces: up, uptime, devices, address counts) in the base package, and dhcp_leases (dnsmasq's and odhcpd's active leases).

The listen interface, port, keepalive, TLS and `omit_zero_values` are set in `/etc/config/prometheus-node-exporter-ucode`; a collector's options go in an optional `config collector '<module>'` section there (`ltq_dsl` for ltq-dsl), where `option enabled '0'` stops serving it.

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

Layout: `src/node_exporter/` is the ucode library (installed to `/usr/share/ucode/node_exporter/`), `files/` the handler, command, init script and config, `openwrt/` the package Makefile, `test/unit/` mirrors `src/`.

## Writing a collector

A collector is a module in `src/node_exporter/collectors/<module>.uc`:

```js
'use strict';

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { first_line, fields } from 'node_exporter.proc';

export const meta = {
	name: 'loadavg',                          // ?collect[]=, the subpackage suffix; may hold '-'
	help: 'Load averages from /proc/loadavg.',
	needs: [ 'fs' ],                          // all it gets in `deps`
	// configs: [ 'dhcp' ],                   // with 'uci': the configs it may read
	// commands: [ 'nft' ],                   // with 'exec': the programs it may run
	// options: { stations: true },           // typed by their defaults; not enabled, the core's
	// paths: [ '/var/run/bmx7/json' ],       // what it reads outside /proc and /sys; see below
};

export function collect(deps, out, options) {
	let x = fields(first_line(deps.fs, '/proc/loadavg'));
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, '/proc/loadavg');

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	return Result.ok();
};
```

- `needs` are `fs` (`readfile open lsdir glob stat realpath`), `ubus` (`call`, `list`, as Results), `uci` (`deps.uci.<config>` for each of `configs`, read-only: `loaded get get_all sections foreach`, committed configuration only), `rtnl` and `nl80211` (`request` as Results, `const`), `socket` (`unix_request(path, message, timeout_ms)`, a Unix socket's whole reply as a Result), `exec` (`run(argv)` as a Result, for `commands` only; a failure's `data.status` is the exit status), `time` (`now()`) and `log` (`log(msg)`, for what a collector that succeeds still has to say). Only `node_exporter.deps` touches the system.
- The exporter runs in procd's jail, which mounts what the installed and enabled collectors declare and nothing else: `/etc/config/<c>` for each of `configs`, `/bin/sh` and each of `commands` (with its libraries), and `paths`. A path may name a string option as `{option}` (textfile's `'{directory}'`), or be a function `(options, uci) => [ paths ]` for what a config decides (dhcp_leases' lease files). A socket is declared by its directory, as ujail cannot mount a socket; a shell script needs what it sources and runs (ubnt-manager).
- `out.gauge|counter|untyped(name, help)` returns `(labels, value)`, which chains; `out.parse(text)` adds exposition text. What a collector records is kept even when it then fails.
- `collect` returns a Result: `ok` is `node_scrape_collector_success 1`; `err` is 0 and one log line.
- An absent kernel feature is nothing to report, for any collector: where nf_conntrack is not loaded (an AP without a firewall), conntrack and nat_traffic return `ok` with no samples. A missing service or program (no unbound control socket, no `ethtool`) is an `err`.

Each collector needs a test in `test/unit/node_exporter/collectors/`, and a line in the package Makefile that depends on what its `needs` and `commands` call for; `test/integration/collectors_test.uc` holds every collector to both.

## Credits

A rewrite of two packages of OpenWrt's feed, both Apache-2.0: [`prometheus-node-exporter-ucode`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-ucode), by Andre Heider (its maintainer) and contributors, and [`prometheus-node-exporter-lua`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-lua), by Jeff Schornick, Kevin Lyda, Christian Simon, Etienne Champetier (its maintainer) and contributors. Metric names and help texts follow the Prometheus [node_exporter](https://github.com/prometheus/node_exporter) and, for unbound and WireGuard, [unbound_exporter](https://github.com/letsencrypt/unbound_exporter) and [prometheus_wireguard_exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter); see [docs/metrics.md](docs/metrics.md). Tests run on [utest](https://github.com/m00qek/utest). [NOTICE](NOTICE) credits each collector's upstream authors.
