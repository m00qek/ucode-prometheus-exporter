# Collector Interface

A collector is a ucode module, `src/prometheus_exporter/collectors/<module>.uc`, installed to `/usr/share/ucode/prometheus_exporter/collectors/`. It imports [the collector API](#the-collector-api) alone, and exports `meta` and `collect`:

```js
'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'loadavg',
	title: 'Load average',
	help: 'Load averages from /proc/loadavg.',
	needs: [ 'fs' ],
};

export function collect(deps, out) {
	let line = proc.first_line(deps.fs, '/proc/loadavg');

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, '/proc/loadavg');

	let x = proc.fields(line);
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, `/proc/loadavg: ${sprintf('%J', line)}`);

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	out.gauge('node_load5', '5m load average.')(null, x[1]);
	out.gauge('node_load15', '15m load average.')(null, x[2]);

	return Result.ok();
};
```

That is `loadavg`, as the base package installs it.

---

## Loading

The loader (`src/prometheus_exporter/loader.uc`) takes every file of the collectors' directory named `[a-z0-9_]+.uc`, imports it, and validates its exports. A module must be in strict mode, its first statement `'use strict'` (after comments only), import `prometheus_exporter.api` and no other module, and its top level must return within 5 seconds: it is first loaded in a process of its own. A module that is not in strict mode, imports another module, does not import in time, or whose `meta` or `collect` is not valid, is left out, and the rest load: the handler logs it at `err`, `check` and the ubus object's `collectors` list it. The collectors are sorted by name.

What the exporter enforces of a collector, and what breaking each rule costs, is in [Collector contract](collector-contract.md).

uhttpd loads them once, when it starts; a scrape runs what was loaded. Installing or removing a collector package reloads the service, which restarts uhttpd.

## `meta`

| Field | Required | Type | Rules |
| :--- | :--- | :--- | :--- |
| `name` | yes | string | `[a-z0-9][a-z0-9_-]*`, and the module's name with `_` for `-`: `ltq-dsl` in `ltq_dsl.uc`. What `collect[]` takes, and the suffix of its package. |
| `title` | yes | string | 1 to 40 characters, no control characters: a label for lists and forms. |
| `help` | yes | string | A sentence: what it collects, and from where. |
| `needs` | yes | array | Capabilities from [`needs`](#needs), once each. All it gets in `deps`. |
| `configs` | with `uci` | array | The uci configs it reads, `[a-z0-9_-]+`, not `prometheus-exporter`: its own settings come as `options`. Not allowed without `uci`. |
| `commands` | with `exec` | array | The programs it runs. Not allowed without `exec`. |
| `optional_commands` | no | array | Those of `commands` it runs only where they are installed: no package it depends on has them, and the jail does without them. |
| `timeout` | no | integer | With `exec`: the seconds its programs get in all per scrape, 1 to 30, unless its section sets `timeout`. Without it, the main section's `exec_timeout`. |
| `max_samples` | no | integer | The samples it may write per scrape, 1 to 100,000, unless its section sets `max_samples`. Without it, the main section's `max_samples` (20,000). |
| `cost` | no | string | `light` (the default) or `heavy`: until the ledger has timed it, a heavy collector runs after the others not yet timed. |
| `options` | no | object | Its own options, `{ <name>: { default, title, help, datatype } }`. See [Options](#options). |
| `paths` | no | array | What it reads outside procfs and sysfs, with `fs`, `socket` or `exec` in `needs`. See [The jail](jail.md#paths). |
| `ubus` | with `ubus` | object | The ubus objects and methods it calls, `{ <object>: [ <method> ] }`, each object once; `<name>.*` for every object whose name starts with `<name>.` (hostapd's `hostapd.*`), and in place of a list a function of its options that gives one, where an option decides (`[]` for none). A call it does not list is `UBUS_NOT_ALLOWED`; the service's ubus ACL allows what the enabled collectors list. Not allowed without `ubus`. |
| `capabilities` | no | array | The capabilities its reads or programs need: `CAP_NET_ADMIN` (nftables, ctnetlink), `CAP_NET_RAW`. |
| `groups` | no | array | The groups whose sockets it connects to, as unbound's `unbound`, whose control socket is `srw-rw----`. |
| `proc_files` | with `fs` | array | The files of `/proc` that only root reads, which it reads, as `/proc/net/nf_conntrack`. |

What `ubus`, `capabilities`, `groups` and `proc_files` grant, and when, is in [The jail](jail.md#the-services-user).

### Options

| Key | Required | Rules |
| :--- | :--- | :--- |
| (the name) | | `[a-z][a-z0-9_]*`; not `enabled`, `timeout`, `budget` nor `max_samples`, which are the core's. |
| `default` | yes | A boolean, an integer or a string: it sets the option's type. |
| `title` | yes | 1 to 40 characters, no control characters: the label a form shows the option by, short and in sentence case, as `Excluded devices`. LuCI shows it as the collector gives it, untranslated. |
| `help` | yes | A sentence: what the option does. |
| `datatype` | no | One of the datatypes the core checks: `uinteger`, `range(min,max)`, `directory`, `file`, `regex`, or `owned_directory`, a directory under `/var`, `/tmp` or `/etc/prometheus-exporter`, for an option that names an owned path. It must take the default. See [UCI configuration](uci-config.md#values). |

`collect` gets the options typed, the defaults for those unset. A value that does not fit fails the collector with `CONFIG_INVALID` in each scrape.

## `collect(deps, out, options)`

| Argument | Content |
| :--- | :--- |
| `deps` | One capability per entry of `meta.needs`, by name. |
| `out` | The recorder the collector writes its families to. |
| `options` | Its own options, typed. |

It returns a Result. Anything else fails it with `COLLECTOR_NO_RESULT`; an exception, with `COLLECTOR_CRASHED`. What it recorded is kept when it fails, and dropped when it has nothing to observe, or when the exporter stopped it (see [Collector contract](collector-contract.md)).

It runs in a process of its own, forked from the scrape's: it shares nothing with the collectors before or after it but the ubus connection and the uci cursor of that process, and it must not end the process (`exit()`).

### Results

`Result`, of the collector API:

| Call | Means | `node_scrape_collector_success` | `node_scrape_collector_observing` | Logged |
| :--- | :--- | :--- | :--- | :--- |
| `Result.ok()` | It observed what it reads. | 1 | 1 | No |
| `Result.err(code, details, data)` | It failed: `code` from the API's `errors`, `details` a string for the log. | 0 | 1 | At `warning`: `collector '<name>': CODE (details)` |
| `Result.none(reason)` | Nothing to observe: its hardware, kernel feature or service is not there. Its samples are dropped. | 1 | 0 | No |

`Result.is(r)` tells a Result, `Result.is_none(r)` one of nothing to observe, `Result.describe(r)` gives `CODE (details)`.

### `services`

The collector API's, for a collector to tell nothing to observe from a failure, over `deps.ubus`:

| Function | Returns |
| :--- | :--- |
| `unless_disabled(ubus, name, failure)` | `Result.none('<name> is disabled')` or `Result.none('<name> is not installed')` when rpcd's `rc` says the init script `name` is not enabled or not there; `failure` otherwise, or when rc cannot say. |
| `idle(ubus, name)` | That reason, or null. |
| `state(ubus, name)` | A Result of `enabled`, `disabled` or `not installed`. |
| `object_missing(res)` | Whether a ubus call failed for its object not being there (`Not found`). |

## The collector API

`prometheus_exporter.api`, the one module a collector imports, exports five objects, each of exactly these names, and two functions. What it exports is what a major version protects; see [Collector contract](collector-contract.md#what-a-collector-may-import).

| Export | Name | Is |
| :--- | :--- | :--- |
| `Result` | `ok`, `err`, `none`, `is`, `is_none`, `describe` | See [Results](#results). |
| `errors` | `SOURCE_UNREADABLE`, `SOURCE_INVALID`, `CONFIG_INVALID` | What a collector fails with, of its own. |
| | `UBUS_CONNECT_FAILED`, `UBUS_CALL_FAILED`, `UBUS_NOT_ALLOWED`, `NL80211_FAILED`, `RTNL_FAILED`, `SOCKET_FAILED`, `COMMAND_NOT_ALLOWED`, `COMMAND_FAILED`, `COMMAND_TIMEOUT`, `PERMISSION_DENIED`, `SCRAPE_DEADLINE`, `EXPOSITION_INVALID` | What its capabilities and `out.parse` fail with. See [Error codes](error-codes.md). |
| `services` | `state`, `idle`, `unless_disabled`, `object_missing`, `ENABLED`, `DISABLED`, `NOT_INSTALLED`, `NOT_FOUND` | See [`services`](#services). |
| `proc` | `first_line(fs, path)` | The first line of a file, without its newline; null when it cannot be read. |
| | `lines(fs, path)` | Every line, without newlines; null when it cannot be read. |
| | `each_line(fs, path, cb)` | `cb(line)` for each line, read one at a time; false when it cannot be read. |
| | `fields(line)` | The whitespace-separated fields of a line; `[]` for none or for null. |
| | `auxv(text)`, `AT_PAGESZ`, `AT_CLKTCK` | An auxiliary vector as `/proc/self/auxv` gives it, `{ type: value }`, or null; two of its types. |
| `exposition` | `parse(text)` | Exposition text read strictly, as a Result of its families (`EXPOSITION_INVALID`). |
| | `format_value(v)` | A value as the format spells it, or null for one that is not a number. |
| | `sanitize(name)` | A metric name made valid: every character the format does not allow an underscore. |
| `u32` | `u32(v)` | A ubus integer a daemon sent as unsigned 32 bits (`blobmsg_add_u32`), unsigned: ucode's ubus gives it signed, so 4294967295 arrives as -1. Anything but a negative 32-bit integer is given back as it is. |
| `u16` | `u16(v)` | The same, for 16 bits (`blobmsg_add_u16`): a port of 51820 arrives as -13716. |

`fs` is the collector's `deps.fs`. `exposition`'s functions load the exposition format the first time one is called.

## `needs`

Only `prometheus_exporter.deps`, with its modules of each capability (`prometheus_exporter.deps.ubus`, `.exec`, ...), touches the system. A collector gets the capabilities it names, and a scrape's collectors share one ubus connection and one uci cursor.

| Need | `deps.<need>` |
| :--- | :--- |
| `fs` | `readfile`, `open`, `lsdir`, `glob`, `stat`, `realpath` of the fs module. Nothing that writes. |
| `ubus` | `call(object, method, args)` and `list()`, as Results. A call `meta.ubus` does not list is `UBUS_NOT_ALLOWED`, without calling. A failed call is `UBUS_CALL_FAILED` with `data.status`, libubus's text, as `Not found`; one the service's ubus ACL refuses is `PERMISSION_DENIED`, and so is an object not found while ubusd has not loaded the ACL. `list()` names the objects the ACL lets the service call. |
| `uci` | `deps.uci.<config>` for each of `meta.configs`, read-only, the committed configuration only: `loaded()`, `get(section, option)`, `get_all(section)`, `sections(type)`, `foreach(type, cb)`. |
| `rtnl` | `request(cmd, flags, attrs)` as a Result (`RTNL_FAILED`), and `const`. |
| `nl80211` | The same, for nl80211 (`NL80211_FAILED`). Needs ucode-mod-nl80211. |
| `socket` | `unix_request(path, message, timeout_ms)`: the whole reply of a Unix stream socket's server, as a Result (`SOCKET_FAILED`). Needs ucode-mod-socket. |
| `exec` | `run(argv)`: a program of `meta.commands`, without a shell's interpretation of its arguments, its standard output as a Result. See [Programs](#programs). |
| `time` | `now()`: the system time, in seconds. |
| `log` | `log(msg)`: a line at `warning`, `collector '<name>': <msg>`, for what a collector that succeeds still has to say. At most 10 lines a run, each cut at 512 bytes; past them, one line once the run is over says how many more were left out. |
| `exporter` | The exporter itself, read-only: `process(file)`, the serving uhttpd's `/proc/<pid>/stat`, `status` or `limits`; `fds()`, how many descriptors it has open; `system(file)`, `/proc/stat` or `/proc/self/auxv`; `counters()`, what the instance's ledger counts, this scrape so far included, or null outside the handler; `samples()`, `{ collector: samples }` of this scrape so far. A collector that needs it runs after every other. The `exporter` collector's. |

A need the system lacks (`nl80211`, `socket`) fails the collector with `NEED_MISSING`, without running it. So does `PERMISSION_DENIED`, when the process lacks a capability of `meta.capabilities`, or may not read a config of `meta.configs` or a file of `meta.proc_files` that is there: read as anyone else, the file would be missing, and the collector would find nothing to observe. A Unix socket it may not connect to (`EACCES`) is `PERMISSION_DENIED` too.

### Programs

- A program not in `meta.commands` is `COMMAND_NOT_ALLOWED`, without running.
- Its standard error is discarded. An exit status other than 0 is `COMMAND_FAILED`, with `data.status`; one that cannot start, `COMMAND_FAILED` with `data.status` null.
- A collector's programs get, in all per scrape, the seconds of its section's `timeout`, else `meta.timeout`, else the main section's `exec_timeout` (5), at most 30. The shell counts whole seconds: they take at most one second more.
- One still running then is killed, with every process it started, and is `COMMAND_TIMEOUT` with `data.timed_out`. So is any `run` after the seconds are spent, without running.

## `out`

`prometheus_exporter.exposition`'s recorder:

| Call | Does |
| :--- | :--- |
| `out.gauge(name, help)`, `out.counter(name, help)`, `out.untyped(name, help)` | Declares a family, and returns `(labels, value)`, which records a sample and returns itself, so calls chain. |
| `out.batch(type, rows)` | Records families of one sample each, without labels: for each row `[ name, help, value ]`, in order, what `out[type](name, help)(null, value)` records, with less work for each. `type` is `'gauge'`, `'counter'` or `'untyped'`. |
| `out.labels(labels)` | Makes a label set several samples share, once, to pass in place of the object. |
| `out.parse(text)` | Adds exposition text, which must be valid as a whole: a Result, `EXPOSITION_INVALID` otherwise. |

- `labels` is an object, or null for none, or what `out.labels()` made. A label whose value is null is left out.
- A value that is not a number is skipped: null, an empty string, a word. A string of digits, or of hex as in sysfs flags, is read as one. `true` and `false` are 1 and 0.
- Names are made valid: every character the format does not allow is an underscore.
- A family declared twice with two types keeps the first, and logs a warning.
- At most `max_samples` samples in all: the next stops the collector (it throws, again at each sample after), and it fails with `SAMPLE_LIMIT`.
- Nothing Prometheus would refuse the whole scrape for: a label value or HELP text that is not valid UTF-8, two label names that are one once sanitized (`if-name` and `if_name`), or labels that are a string of the collector's own. The sample stops the collector as the one past `max_samples` does, and it fails with `EXPOSITION_INVALID`, naming the family and the label.
- A family is the first collector's that writes it: one another collector writes, or one of the exporter's own (`node_scrape_collector_*`, `ucode_prometheus_exporter_*`), fails the collector with `FAMILY_CONFLICT`.

## Tests and packaging

Every collector has a unit test, `test/unit/prometheus_exporter/collectors/<module>_test.uc`, and a package: in the base package's `BASE_COLLECTORS`, or a `Collector` line of the package Makefile that depends on what its `needs` and `commands` call for. `test/integration/collectors_test.uc` holds every collector to both. See [How to package a collector](../how-to/developer/package-collector.md).

A unit test runs the collector with `test/context.uc`'s `with_collector`, which fails the test when the collector touches a path, a socket or a program its `meta` does not declare: see [Collector contract](collector-contract.md#in-the-tests).

## See also

- [Tutorial: write your first collector](../tutorials/first-collector.md)
- [About nothing to observe](../explanation/nothing-to-observe.md)
- [About the architecture](../explanation/architecture.md)
