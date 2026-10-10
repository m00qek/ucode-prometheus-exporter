# The Devkit

`ucode-prometheus-exporter-devkit` is what a collector is tested with, under [utest](https://github.com/m00qek/utest): the exporter's own collectors, and those of any other package. It installs its modules to `/usr/share/ucode/prometheus/exporter/devkit/`, and depends on the exporter of the same release, `ucode-utest`, `ucode-mod-nl80211` and `ucode-mod-socket`. It is for a development machine or a CI image, not for a router.

What its modules export, and what their configs and callbacks hold, is what a major version of the exporter protects, as [the collector API](collector-interface.md#the-collector-api) is: see [About versions](../explanation/versions.md#what-a-version-promises). How to use it is in [How to write a collector in your own package](../how-to/collector-package.md).

---

## The utest config

A collector package's `test/utest.config.uc`, as the template's: its module on the path, and the mocks `with_collector` builds a collector's capabilities from.

```js
return {
	pattern: '*_test.uc',
	lib_paths: [ '../src' ],
	mocks: {
		fs:      null,
		uci:     null,
		ubus:    { proxy: '/usr/share/ucode/prometheus/exporter/devkit/proxies/ubus.uc' },
		rtnl:    { proxy: '/usr/share/ucode/prometheus/exporter/devkit/proxies/rtnl.uc' },
		nl80211: { proxy: '/usr/share/ucode/prometheus/exporter/devkit/proxies/nl80211.uc' },
		socket:  { proxy: '/usr/share/ucode/prometheus/exporter/devkit/proxies/socket.uc' },
	},
};
```

All six are needed, whatever the collector needs: `with_collector` builds the session of every capability. `fs` and `uci` are utest's own proxies.

## `prometheus.exporter.devkit.collector`

| Export | Is |
| :--- | :--- |
| `with_collector(mod, cfg, cb)` | Runs collector module `mod` (its exports) as a scrape does, with only its `needs`, over the mocks of `cfg`, and calls `cb(r)` with its run. It holds the collector to its contract first, and fails the test, with `assert.fail()`, before `cb` runs: see [Collector contract](collector-contract.md#in-the-tests). It asserts nothing of the Result: the test does. |
| `outcome(r)` | `{ ok, none, error, lines, logs }` of a run: what a test checks of one that fails or has nothing to observe. |
| `jail_of(mod, cfg)` | What the service's jail gives the collector: its mounts, configs, commands, ubus calls and grants, as `prometheus.exporter.jail` works them out. |
| `with_mods(cfg, cb, id)` | utest's mocks injected, `cb` called with module-shaped objects for a session, as the exporter's real modules are; `id` puts `cfg.options` in that collector's section. |
| `module_problems(text)` | What the loader and `collector check` refuse of a module's text, before loading it, each with its line: not in strict mode, an import other than the collector API, [a top level that does more than declare](collector-interface.md#the-top-level). `[]` for none. |
| `assert_module(path)` | Fails the test when `module_problems()` of the file at `path` names any. |
| `MOCKED` | `[ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket' ]`, the mocks the utest config names. |

### `cfg`

Every key is optional.

| Key | Is |
| :--- | :--- |
| `fs`, `ubus`, `uci`, `rtnl`, `nl80211`, `socket` | Each mock's config, as utest and the proxies below take it: `{ data, errors, behavior, strict }`. A mock is strict unless its config says `strict: false`: what it does not hold fails the test. |
| `options` | The collector's own options, its `config collector` section, as uci holds them: strings, `'0'` and `'1'` for a boolean. |
| `main` | The exporter's main section. |
| `no_nl80211`, `no_rtnl`, `no_socket` | As if that module were not installed: the collector fails `NEED_MISSING`. |
| `time` | What `deps.time.now()` returns. |
| `self_status` | The text of `/proc/self/status` the session checks `meta.capabilities` against. |
| `unreadable` | The paths the service's user may not read (a config, a proc file); without it nothing is checked. |
| `outside_jail` | Paths a collector looks for knowing the jail never has them, for where it runs outside it: the mocks answer them, and the contract check lets them be. |
| `files`, `absent` | `jail_of()` alone: the regular files commands are found among, and the paths that are not there; any other path is, as a directory. |

### The run, `r`

| Field | Is |
| :--- | :--- |
| `result` | The collector's Result. |
| `text`, `lines` | What it wrote, as the exposition format, and its lines. |
| `logs`, `levels` | What the scrape and the collector logged, and the level of each. |
| `families` | Its families as the format reads them back: `{ name, type, help, samples }`. |

A breach of the contract is recorded during the run and fails the test after it, never from inside: the collector's error boundary would take a failure there for a crash, and a collector that falls back on a default (`readfile(p) ?? ''`) would pass.

## `prometheus.exporter.devkit.fixtures`

| Export | Is |
| :--- | :--- |
| `reader(dir)` | A reader of the fixtures under `dir`, relative to where utest runs, or absolute (`sourcepath(0, true)` gives a test's own directory): `file(path)`, a file's text by the path it has on the device (`<dir>/proc/loadavg` for `/proc/loadavg`); `files(paths)`, several, as an fs mock's `data`; `ubus(object, method)`, the JSON of `<dir>/ubus/<object>.<method>.json`. A fixture that is not there fails the test, naming it. |

## `prometheus.exporter.devkit.commands`

For a collector that needs `exec`: an fs mock whose `popen` answers each program, as the exec capability runs it, under its watchdog.

| Export | Is |
| :--- | :--- |
| `fs(outputs, extra)` | An fs mock config whose `popen` answers `outputs[line(argv)]`: `{ out, status }`; `{ hangs: true }`, a program its watchdog killed (`COMMAND_TIMEOUT`); `{ run: argv, seconds }`, `argv` run for real under the real watchdog. A command line not there cannot start (`COMMAND_FAILED`). `extra` is merged into the config: its `data`, say. |
| `line(argv)` | A command line as the capability runs it, each argument single-quoted: the key of `outputs`. |
| `parse(script)` | `{ seconds, line }` of a script the capability gives `popen`, or null. |
| `running(text)` | The command lines of the processes whose command line holds `text`, looked for again for up to a second: that none a program started outlives it. |

```js
with_collector(mine, { fs: commands.fs({ [commands.line([ 'tc', '-s', '-j', 'qdisc', 'show' ])]: { out: '[]', status: 0 } }) }, (r) => ...);
```

## `prometheus.exporter.devkit.rc`

For a collector that tells a disabled service from a failure, with the API's `services`.

| Export | Is |
| :--- | :--- |
| `rc(scripts)` | A ubus mock's data of rpcd's `rc list`, as 25.12's rpcd answers it: `{ 'rc:list': ... }`, `{ <name>: { start, enabled } }` for an init script `scripts` names, `{}` for any other, which is not installed. Merge it: `{ ...rc({ dnsmasq: true }), 'dnsmasq:metrics': ... }`. |
| `list(scripts)` | Its method, a function of the call's arguments. |

## The proxies

`proxies/<name>.uc`, utest proxies, which the utest config names. Each takes `data` and the channels below, keyed as said; each call is recorded, as utest's are.

| Proxy | Keys | Channels |
| :--- | :--- | :--- |
| `ubus` | `object:method`, or `object` for every method of it. A value is a reply, or a function of the call's arguments that returns one. | `errors`: the message `error()` reports after the call, which then returns null (`Not found`, `Permission denied`). `list()` names every object `data` names; `list(path)` answers one of them, and `system`, with `[ {} ]`, or for `list:<path>` in `errors` with `[]`. |
| `rtnl` | The command as rtnl's constants name it, with the device where the request has one: `RTM_GETLINK:eth0`, else `RTM_GETLINK`. A value is a reply, or a function of `(flags, attrs)`. | `errors`: the message after that request fails. |
| `nl80211` | As rtnl's: `NL80211_CMD_GET_STATION:phy0-ap0`. | `errors`. |
| `socket` | A Unix socket's path. A value is the server's whole reply, or a function of the request. | `errors`: the message after `connect()` fails there (`connect(): Connection refused`); `hangs`: the server replies and never closes, so the next read times out. Any other path is missing (`ENOENT`). |

The devkit ships its own proxies because utest 1.5 has none for rtnl, nl80211 or socket, and its ubus proxy lacks `list()` and `error()`; `commands.fs()` replaces utest's popen mock, whose handle closes without the exit status 25.12's ucode gives. The proxies are programs, hence their top-level `return`.

## See also

- [How to write a collector in your own package](../how-to/collector-package.md)
- [Collector interface](collector-interface.md) and [Collector contract](collector-contract.md)
