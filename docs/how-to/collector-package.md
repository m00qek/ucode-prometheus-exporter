# How to Write a Collector in Your Own Package

A collector of yours, in an OpenWrt package of your own, tested with the exporter's devkit and installed beside the exporter's packages. The exporter loads it as it loads its own, from `/usr/share/ucode/prometheus_exporter/collectors/`, and holds it to the same rules.

## Prerequisites

- The exporter's source, for its template: `devkit/template/` of the [repository](https://github.com/m00qek/ucode-prometheus-exporter), or of a release's tarball.
- An [OpenWrt SDK](https://openwrt.org/docs/guide-developer/toolchain/using_the_sdk) of 25.12, to build the package; `ghcr.io/openwrt/sdk:<arch>-25.12.<n>` is one.
- Somewhere to run its tests: an OpenWrt 25.12 rootfs container (`ghcr.io/openwrt/rootfs:x86_64-25.12.<n>`), with the [packages.ucode.dev](https://github.com/m00qek/packages.ucode.dev) feed added, as [Installing the exporter](install.md) adds it.

---

## 1. Start from the template

```sh
cp -r ucode-prometheus-exporter/devkit/template my-collector
cd my-collector
```

| File | Is |
| :--- | :--- |
| `Makefile` | The OpenWrt package, `ucode-prometheus-exporter-example`. |
| `src/prometheus_exporter/collectors/example.uc` | The collector, `example`: seconds since boot from `/proc/uptime`, and each swap area from `/proc/swaps`. |
| `test/example_test.uc` | Its tests. |
| `test/fixtures/router/` | What a router answered, at the paths it has there. |
| `test/utest.config.uc` | utest's config, on the devkit. |

Rename `example` everywhere: the module's file and `meta.name` (the module's name, with `-` for `_`), its test, and `PKG_NAME`. The exporter finds a collector by its file, never by its package's name; `ucode-prometheus-exporter-<name>` keeps it beside the exporter's in a list, but a name of your own avoids one the exporter may take for a collector of its own later.

## 2. Write to the collector API

A collector imports `prometheus_exporter.api` and nothing else: the loader leaves out one that imports `fs` or `ubus`, or calls `require`. What it reads of the system comes through `deps`, the capabilities its `meta.needs` names.

```js
import { Result, errors, services, proc, exposition, u32 } from 'prometheus_exporter.api';
```

What the API exports, `collect(deps, out, options)`, each capability of `deps` and the recorder `out` are in [Collector interface](../reference/collector-interface.md). Two of them write the most for the least:

- **`proc.rows(fs, path)`**, the fields of every line of a file, `[]` for a blank one: a table of `/proc` in one call, as the template reads `/proc/swaps`.
- **`out.batch(type, rows)`**, families of one sample each, without labels: `[ [ name, help, value ], ... ]`, as the template writes the uptime.

They, and every name the API exports, are what a version of the exporter promises a collector: see [About versions](../explanation/versions.md#the-collector-api).

## 3. Declare what it touches

`meta` says what the collector is and what it reaches. The service builds its jail from it, and grants its user, which is not root, what it declares and nothing else: a path it does not declare is not there, a ubus call it does not list is refused.

| `meta` | Declare | The jail, from it |
| :--- | :--- | :--- |
| `needs` | The capabilities it gets in `deps`: `fs`, `ubus`, `uci`, `rtnl`, `nl80211`, `socket`, `exec`, `time`, `log`. | — |
| `paths` | What it reads outside `/proc` and `/sys`, and the directory of each Unix socket it connects to. | Mounts each, read-only. |
| `configs` | With `uci`: the uci configs it reads. | Mounts each, readable by the service's group. |
| `commands` | With `exec`: the programs it runs; `optional_commands`, those it runs only where they are installed. | Mounts each, with its libraries. |
| `ubus` | With `ubus`: `{ object: [ method ] }`, `name.*` for every object under `name.`. | Writes the service's ubus ACL. |
| `capabilities` | `CAP_NET_ADMIN` or `CAP_NET_RAW`, for what its reads or programs need. | Grants it to the service. |
| `groups` | The groups whose sockets it connects to. | Puts the service's user in each. |
| `proc_files` | With `fs`: the files of `/proc` only root reads, which it reads. | Opens each to the service's group. |

Each field's rules are in [Collector interface](../reference/collector-interface.md#meta), and what each grants in [The jail](../reference/jail.md#the-services-user). The tests below fail a collector that touches what it does not declare.

## 4. Keep the top level to declarations

The module's top level runs twice each time the service starts: in a child process, guarded, and again in uhttpd's own process, which every scrape is forked from. So it only declares: constants, functions, `meta`, `collect` and the import, with calls of ucode's functions that compute alone (`regexp`, `sprintf`, `map`, `join` ...). A top level that sleeps, prints, exits or loads code is left out, `COLLECTOR_IMPURE`; one that loops is left out after 5 seconds. Whatever it reads or works out belongs in `collect()`:

```js
const LINE = regexp('^([a-z]+) ([0-9]+)$');   // a constant: fine

export function collect(deps, out) {
	let text = deps.fs.readfile('/proc/mine');  // reads: in collect() alone
	...
};
```

The full list is in [The top level](../reference/collector-interface.md#the-top-level).

## 5. Depend on what it reads with, never on what it watches

In the `Makefile`, `DEPENDS` names what the collector reads WITH: the exporter, a library (`+ucode-mod-nl80211` for `nl80211`, `+ucode-mod-socket` for `socket`), a generic program it runs (`+tc`, `+ethtool`). Never what it WATCHES: installing a monitoring package must not install, and start, a daemon that changes what the router does. Where what it watches is not there, the collector has nothing to observe, `Result.none('<what> is not installed')`, and the API's `services.unless_disabled()` says so for a service that is installed but disabled. A program that comes with what it watches (`chronyc` with chrony) goes in `meta.optional_commands`. See [About nothing to observe](../explanation/nothing-to-observe.md).

## 6. Test it

On the test machine, install the devkit, which brings the exporter and utest:

```sh
apk add ucode-prometheus-exporter-devkit
cd my-collector
utest -c test/utest.config.uc test
```

`with_collector` runs the collector as a scrape does, with only its `needs`, over the mocks the test gives it, and fails the test when it touches a path, a socket, a program or a ubus call its `meta` does not declare, writes text Prometheus would refuse, or has a `meta` the loader refuses. `assert_module` fails one the loader would leave out for its text: not strict, another import, or a top level that does more than declare.

```js
import { with_collector, outcome, assert_module } from 'prometheus_exporter.devkit.collector';
import { reader } from 'prometheus_exporter.devkit.fixtures';
import * as mine from 'prometheus_exporter.collectors.mine';

const ROUTER = reader(sourcepath(0, true) + '/fixtures/router');

it('writes what the router has', () => {
	with_collector(mine, { fs: { data: ROUTER.files([ '/proc/mine' ]) } }, (r) => {
		assert.match(true, r.result.ok);
		assert.match([ '# HELP mine_value ...', ... ], r.lines);
	});
});
```

Capture fixtures from a device as it has them: a file at its own path under the fixtures' directory, a ubus reply as `ubus/<object>.<method>.json`, from `ubus call <object> <method>`. What the devkit exports, `with_collector`'s config, the programs' and `rc`'s mocks and the proxies' keys are in [The devkit](../reference/devkit.md).

## 7. Package it

The template's `Makefile` installs the module into the collectors' directory and reloads an enabled exporter when the package is installed or removed, which restarts it with the collector loaded or gone. It depends on the exporter of the API it is written to, `EXPORTER_MIN`, 0.3.0, which froze the API for 1.0; from 1.0, `>=1.0.0`, as only a major version breaks it.

```sh
cp -r my-collector <sdk>/package/
cd <sdk>
make defconfig
make package/ucode-prometheus-exporter-mine/compile
```

The `.apk` is under `bin/packages/<arch>/base/`. Publish it in a feed of yours, or install it as a file:

```sh
apk add --allow-untrusted ucode-prometheus-exporter-mine-1.0.0-r1.apk
```

## 8. Check it on a device

```sh
prometheus-exporter collector check /usr/share/ucode/prometheus_exporter/collectors/mine.uc
wget -qO- http://127.0.0.1:9100/metrics | grep 'collector="mine"'
```

`collector check` reads the module's text, loads it under the guards, validates its `meta`, runs it on the device, and fails what the exporter would leave out or stop; see [The prometheus-exporter command](../reference/command.md#collector-check). `node_scrape_collector_success{collector="mine"} 1` says it is served.

## See also

- [Collector interface](../reference/collector-interface.md), [Collector contract](../reference/collector-contract.md) and [The devkit](../reference/devkit.md)
- [Tutorial: write your first collector](../tutorials/first-collector.md), in the exporter's own tree
