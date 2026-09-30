# prometheus-node-exporter-ucode

Node metrics for Prometheus from OpenWrt, written in ucode and served by uhttpd at `/metrics`. A rewrite of OpenWrt's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`: the same package name, port (9101), config file and metric names, with the Lua exporter's collectors ported alongside.

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

The listen interface, port, keepalive, TLS and `omit_zero_values` are set in `/etc/config/prometheus-node-exporter-ucode`; a collector's own options go in a `config collector '<module>'` section there.

## Developing

Everything runs in OpenWrt's own images (Docker), on the release in `OPENWRT_VERSION` (25.12.5 by default; CI also runs 25.12.0).

| | |
|---|---|
| `make test` | unit and integration tests (utest); `unit`, `integration`, `watch`; `FILTER=`, `VERBOSE=1`, `MODULES=` |
| `make lint` | loads every module on 25.12's ucode, so a function it lacks fails here |
| `make package` | the apks, built with the OpenWrt SDK, into `bin/` |
| `make package-check` | installs them offline and scrapes a real uhttpd on loopback |
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
	// commands: [ 'nft' ],                   // with 'exec': the programs it may run
	// options: { stations: true },           // typed by their defaults
};

export function collect(deps, out, options) {
	let x = fields(first_line(deps.fs, '/proc/loadavg'));
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, '/proc/loadavg');

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	return Result.ok();
};
```

- `needs` are `fs` (`readfile open lsdir glob stat realpath`), `ubus` (`call`, `list`, as Results), `uci` (a cursor), `rtnl` and `nl80211` (`request` as Results, `const`), `exec` (`run(argv)` as a Result, for `commands` only) and `time` (`now()`). Only `node_exporter.deps` touches the system.
- `out.gauge|counter|untyped(name, help)` returns `(labels, value)`, which chains; `out.parse(text)` adds exposition text. What a collector records is kept even when it then fails.
- `collect` returns a Result: `ok` is `node_scrape_collector_success 1`; `err` is 0 and one log line.

Each collector needs a test in `test/unit/node_exporter/collectors/`, and a line in the package Makefile that depends on what its `needs` and `commands` call for; `test/integration/collectors_test.uc` holds every collector to both.
