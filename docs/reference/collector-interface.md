# Collector Interface

A collector is a ucode module. Its source is `src/prometheus/collectors/<module>.uc`, and it is installed to `/usr/share/ucode/prometheus/collectors/`. It imports only [the collector API](#the-collector-api), and exports `meta` and `collect`:

```js
'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

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

This is the `loadavg` collector, as the base package installs it.

---

## Loading

The loader (`src/prometheus/exporter/loader.uc`) imports every file of the collectors' directory whose name matches `[a-z0-9_]+.uc`, and validates its exports. A module must:

- be in strict mode: its first statement is `'use strict'`, with only comments before it;
- import `prometheus.exporter`, and no other module;
- [only declare](#the-top-level) at its top level, and finish loading within 5 seconds (the loader first loads it in a process of its own);
- export a valid `meta` and `collect`.

The loader leaves out a module that breaks one of these rules, and loads the rest. The handler logs the module at `err`, and `check` and the ubus object's `collectors` list it. The loader sorts the collectors by name.

[Collector contract](collector-contract.md) lists what the exporter enforces on a collector, and what breaking each rule costs.

uhttpd loads the collectors once, when it starts. A scrape runs the collectors loaded then. Installing or removing a collector package reloads the service, which restarts uhttpd.

Each collector gets its own capabilities, copies included. A collector that overwrites one of their functions changes nothing for the collectors after it. uci cursors read only the committed configuration, never changes that are staged and not yet committed.

## The top level

A module's top level runs twice each time the service starts:

1. in a child process, where the probe stops it at 5 seconds;
2. in uhttpd's own process, which every scrape is forked from, and where nothing guards it.

So the top level only declares, and leaves the work to `collect()`. It may hold:

- `'use strict'`, and its import of `prometheus.exporter`;
- constants and variables (`const`, `let`) and functions, and their exports, `meta` and `collect` among them;
- values built from literals, regular expressions, templates, objects and arrays, functions (not called), operators, and names it declared earlier;
- calls to the ucode functions that compute only from their arguments: `arrtoip`, `assert`, `b64dec`, `b64enc`, `chr`, `exists`, `filter`, `hex`, `hexdec`, `hexenc`, `index`, `int`, `iptoarr`, `join`, `json`, `keys`, `lc`, `length`, `ltrim`, `map`, `match`, `max`, `min`, `ord`, `pop`, `push`, `regexp`, `replace`, `reverse`, `rindex`, `rtrim`, `shift`, `slice`, `sort`, `splice`, `split`, `sprintf`, `substr`, `trim`, `type`, `uc`, `uchr`, `uniq`, `unshift`, `values`, `wildcard`; and to the collector API functions that do the same: `Result`'s, `proc.fields`, `proc.auxv`, `u16`, `u32`.

```js
const FIELDS = [ 'rx_bytes', 'tx_bytes' ];
const LINE = regexp('^(' + join('|', FIELDS) + ') ([0-9]+)$');  // ok: pure calls
const UPPER = map(FIELDS, (f) => uc(f));                         // ok

const HOME = getenv('HOME');                 // not ok: reads the process's environment
const ONE = proc.first_line(fs, '/proc/x');  // not ok: no fs here; read it in collect()
for (let f in FIELDS) TABLE[f] = true;       // not ok: a statement; declare TABLE whole
```

| Where | Holds it to | Broken |
| :--- | :--- | :--- |
| Every load: the probe's child, uhttpd, rpcd's helpers, the command line | While the top level runs, `sleep`, `system`, `exit`, `print`, `printf`, `warn`, `trace`, `require`, `include`, `loadfile`, `loadstring`, `render` and `signal` refuse to run. They block, end or write to the process, load code (and through `require`, read files, run programs and open sockets), or change its signals. The collector API's `exposition` functions load the format with `loadstring`, so they are refused too. In the child, the probe stops a loop that never ends at 5 s. Once the top level has run, the loader puts the global scope back as it was. It refuses a top level that changed it, with `global.sort = ...` or a name of its own in `global`. | Left out, logged at `err`: `skipping collector: COLLECTOR_IMPURE (<module>: its top level called sleep(), which blocks the process: ...)`, or `... its top level changed the global scope, sort: ...`; a loop, `collector '<module>' hung at load`. |
| Always: the top level and `collect()` | The collector API's exports (`Result`, `errors`, `services`, `proc` and `exposition`) and a Result's prototype are constant. Every collector loaded with the API shares them, so writing over one, `Result.ok = ...`, fails with `object value is immutable`. | At the top level, the module is left out: `skipping collector: COLLECTOR_IMPURE (<module>: its top level wrote over what the collector API exports, which no collector may change: ...)`. In `collect()`, the run fails with `COLLECTOR_CRASHED`. |
| `prometheus-exporter collector check`, the repository's tests, and a collector package's tests with the devkit | The module's text, outside the bodies of its functions: no statement but declarations, and no call but to the functions above. | `FAIL its top level calls getenv() (line 4): ...`, `FAIL its top level runs 'for' (line 6): ...`. |

`push`, `pop`, `shift`, `unshift`, `splice` and `sort` change the array they are given. At the top level they can only reach the module's own arrays, because the API's values are constant, so the top level may call them. It may not call `proto`: every collector shares a Result's prototype.

The loader does not read the module's text. Reading a module a character at a time would cost a router's uhttpd seconds when it starts. Instead, the guard around each load refuses each forbidden call as the module makes it. The text check does not read a function that the top level calls through `map()` or `sort()`, but the guard holds that function to the rules as it runs. See [Error codes](error-codes.md#collectors-and-their-sources).

## `meta`

| Field | Required | Type | Rules |
| :--- | :--- | :--- | :--- |
| `name` | yes | string | `[a-z0-9][a-z0-9_-]*`. The module's file name is the name with `_` for `-`: `ltq-dsl` in `ltq_dsl.uc`. `collect[]` takes this name, and it is the suffix of the collector's package. |
| `title` | yes | string | 1 to 40 characters, no control characters: a label for lists and forms. |
| `help` | yes | string | A sentence: what it collects, and from where. |
| `needs` | yes | array | Capabilities from [`needs`](#needs), each once. `deps` gets only these. |
| `configs` | with `uci` | array | The uci configs it reads, `[a-z0-9_-]+`. Not `prometheus-exporter`: the collector gets its own settings as `options`. Not allowed without `uci`. |
| `commands` | with `exec` | array | The programs it runs. Not allowed without `exec`. |
| `optional_commands` | no | array | The `commands` it runs only where they are installed. No package it depends on provides them, and the jail works without them. |
| `timeout` | no | integer | With `exec`: the seconds its programs get in total per scrape, 1 to 30. Its section's `timeout` overrides it. Without either, the main section's `exec_timeout` applies. |
| `max_samples` | no | integer | The samples it may write per scrape, 1 to 100,000. Its section's `max_samples` overrides it. Without either, the main section's `max_samples` (20,000) applies. |
| `cost` | no | string | `light` (the default) or `heavy`. Until [the ledger](jail.md#the-ledger) has timed it, a heavy collector runs after the other collectors not yet timed. |
| `options` | no | object | Its own options, `{ <name>: { default, title, help, datatype } }`. See [Options](#options). |
| `paths` | no | array | What it reads outside procfs and sysfs, with `fs`, `socket` or `exec` in `needs`. See [The jail](jail.md#paths). |
| `ubus` | with `ubus` | object | The ubus objects and methods it calls, `{ <object>: [ <method> ] }`, each object once. `<name>.*` stands for every object whose name starts with `<name>.` (hostapd's `hostapd.*`). Where an option decides the methods, a function of the options can replace the list and return one (`[]` for none). A call it does not list fails with `UBUS_NOT_ALLOWED`. The service's ubus ACL allows what the enabled collectors list. Not allowed without `ubus`. |
| `capabilities` | no | array | The capabilities its reads or programs need: `CAP_NET_ADMIN` (nftables, ctnetlink), `CAP_NET_RAW`. |
| `groups` | no | array | The groups whose sockets it connects to, such as `unbound` for unbound's control socket, which is `srw-rw----`. |
| `proc_files` | with `fs` | array | The files of `/proc` that only root can read and that it reads, such as `/proc/net/nf_conntrack`. |

[The jail](jail.md#the-services-user) says what `ubus`, `capabilities`, `groups` and `proc_files` grant, and when.

### Options

| Key | Required | Rules |
| :--- | :--- | :--- |
| (the name) | | `[a-z][a-z0-9_]*`. Not `enabled`, `timeout`, `budget` or `max_samples`: those belong to the core. |
| `default` | yes | A boolean, an integer or a string. It sets the option's type. |
| `title` | yes | 1 to 40 characters, no control characters. The label a form shows for the option: short and in sentence case, such as `Excluded devices`. LuCI shows it as the collector gives it, untranslated. |
| `help` | yes | A sentence: what the option does. |
| `datatype` | no | One of the datatypes the core checks: `uinteger`, `range(min,max)`, `directory`, `file`, `regex`, `ipaddr` (an IPv4 or IPv6 address, without a prefix), or `owned_directory` (a directory under `/var`, `/tmp` or `/etc/prometheus-exporter`, for an option that names an owned path). The default must pass it. See [UCI configuration](uci-config.md#values). |

`collect` gets the options typed, with the default for each option left unset. A value that does not fit its option fails the collector with `CONFIG_INVALID` in every scrape.

## `collect(deps, out, options)`

| Argument | Content |
| :--- | :--- |
| `deps` | One capability per entry of `meta.needs`, by name. |
| `out` | The recorder the collector writes its families to. |
| `options` | Its own options, typed. |

`collect` returns a Result. If it returns anything else, it fails with `COLLECTOR_NO_RESULT`. If it throws, it fails with `COLLECTOR_CRASHED`. The exporter keeps what the collector recorded when it fails. It drops it when the collector has nothing to observe, or when the exporter stopped it (see [Collector contract](collector-contract.md)).

The collectors run one after the other in a child process forked from the scrape's process. A collector shares nothing with the collectors before and after it but that process's ubus connection and uci cursor. It must not end the process (`exit()`).

### Results

The collector API's `Result`:

| Call | Means | `node_scrape_collector_success` | `node_scrape_collector_observing` | Logged |
| :--- | :--- | :--- | :--- | :--- |
| `Result.ok()` | It observed what it reads. | 1 | 1 | No |
| `Result.err(code, details, data)` | It failed: `code` from the API's `errors`, `details` a string for the log. | 0 | 1 | At `warning`: `collector '<name>': CODE (details)` |
| `Result.none(reason)` | Nothing to observe: its hardware, kernel feature or service is not there. Its samples are dropped. | 1 | 0 | No |

`Result.is(r)` tells whether `r` is a Result, and `Result.is_none(r)` whether it is one of nothing to observe. `Result.describe(r)` gives `CODE (details)`.

### `services`

The collector API's `services` helps a collector tell nothing to observe from a failure. Its functions work over `deps.ubus`:

| Function | Returns |
| :--- | :--- |
| `unless_disabled(ubus, name, failure)` | `Result.none('<name> is disabled')` or `Result.none('<name> is not installed')` when rpcd's `rc` says the init script `name` is not enabled or not there. `failure` otherwise, or when rc cannot say. |
| `idle(ubus, name)` | That reason, or null. |
| `state(ubus, name)` | A Result of `enabled`, `disabled` or `not installed`. |
| `object_missing(res)` | Whether a ubus call failed because its object is not there (`Not found`). |

## The collector API

`prometheus.exporter` is the only module a collector imports. It exports five objects, each with exactly the names below, and two functions. These exports are what a major version protects; see [Collector contract](collector-contract.md#what-a-collector-may-import).

| Export | Name | Is |
| :--- | :--- | :--- |
| `Result` | `ok`, `err`, `none`, `is`, `is_none`, `describe` | See [Results](#results). |
| `errors` | `SOURCE_UNREADABLE`, `SOURCE_INVALID`, `CONFIG_INVALID` | The codes a collector fails with on its own. |
| | `UBUS_CONNECT_FAILED`, `UBUS_CALL_FAILED`, `UBUS_NOT_ALLOWED`, `NL80211_FAILED`, `RTNL_FAILED`, `SOCKET_FAILED`, `COMMAND_NOT_ALLOWED`, `COMMAND_FAILED`, `COMMAND_TIMEOUT`, `PERMISSION_DENIED`, `SCRAPE_DEADLINE`, `EXPOSITION_INVALID` | The codes its capabilities and `out.parse` fail with. See [Error codes](error-codes.md). |
| `services` | `state`, `idle`, `unless_disabled`, `object_missing`, `ENABLED`, `DISABLED`, `NOT_INSTALLED`, `NOT_FOUND` | See [`services`](#services). |
| `proc` | `first_line(fs, path)` | The first line of a file, without its newline; null when it cannot be read. |
| | `lines(fs, path)` | Every line, without newlines; null when it cannot be read. |
| | `each_line(fs, path, cb)` | `cb(line)` for each line, read one at a time; false when it cannot be read. |
| | `fields(line)` | The whitespace-separated fields of a line; `[]` for none or for null. |
| | `rows(fs, path)` | The fields of every line, as `fields()` gives them, with `[]` for a blank line; null when it cannot be read. For a file of single spaces, it is cheaper than `fields()` on each line. |
| | `auxv(text)`, `AT_PAGESZ`, `AT_CLKTCK` | An auxiliary vector as `/proc/self/auxv` gives it, as `{ type: value }`, or null. `AT_PAGESZ` and `AT_CLKTCK` are two of its types. |
| `exposition` | `parse(text)` | Exposition text read strictly, as a Result of its families (`EXPOSITION_INVALID`). |
| | `format_value(v)` | A value as the format spells it, or null for one that is not a number. |
| | `sanitize(name)` | A metric name made valid: each character the format does not allow becomes an underscore. |
| `u32` | `u32(v)` | Makes a ubus integer unsigned again when a daemon sent it as unsigned 32 bits (`blobmsg_add_u32`). ucode's ubus gives it signed, so 4294967295 arrives as -1. Anything but a negative 32-bit integer comes back unchanged. |
| `u16` | `u16(v)` | The same, for 16 bits (`blobmsg_add_u16`): a port of 51820 arrives as -13716. |

`fs` is the collector's `deps.fs`.

Each exported object lists exactly the names a collector may use, rather than re-exporting a whole core module. That list is what a major version protects. Every collector compiles its own copy of each module it imports. So the API imports only small modules, and loads the exposition format only the first time one of the `exposition` functions is called.

## `needs`

Only `prometheus.exporter.deps` touches the system, through its module for each capability (`prometheus.exporter.deps.ubus`, `.exec`, ...). A collector gets the capabilities it names. A scrape's collectors share one ubus connection and one uci cursor.

| Need | `deps.<need>` |
| :--- | :--- |
| `fs` | `readfile`, `open`, `lsdir`, `glob`, `stat`, `realpath` of the fs module. Nothing that writes. |
| `ubus` | `call(object, method, args)` and `list()`, as Results. A call that `meta.ubus` does not list is `UBUS_NOT_ALLOWED`, and is not made. A failed call is `UBUS_CALL_FAILED`, with libubus's text in `data.status`, such as `Not found`. A call the service's ubus ACL refuses is `PERMISSION_DENIED`. So is an object not found while ubusd has not loaded the ACL. `list()` names the objects the ACL lets the service call. |
| `uci` | `deps.uci.<config>` for each of `meta.configs`, read-only, the committed configuration only: `loaded()`, `get(section, option)`, `get_all(section)`, `sections(type)`, `foreach(type, cb)`. |
| `rtnl` | `request(cmd, flags, attrs)` as a Result (`RTNL_FAILED`), and `const`. |
| `nl80211` | The same, for nl80211 (`NL80211_FAILED`). Needs ucode-mod-nl80211. |
| `socket` | `unix_request(path, message, timeout_ms)`: the whole reply of a Unix stream socket's server, as a Result (`SOCKET_FAILED`). `tcp_request(address, port, message, timeout_ms)`: the same, for a TCP port of the device itself. The address must be one of the device's own IPv4 or IPv6 addresses, and the socket binds to it before it connects. Any other address fails with `SOCKET_FAILED`, without connecting. `timeout_ms` bounds every wait: to connect, to send and to read. The reply is what the server sent until it closed. Needs ucode-mod-socket. |
| `exec` | `run(argv)` runs a program of `meta.commands`, with no shell interpreting its arguments, and gives its standard output as a Result. `run_all(argvs)` runs several, one after the other under one watchdog, and gives a Result for each, as `run` does. See [Programs](#programs). |
| `time` | `now()`: the system time, in seconds. |
| `log` | `log(msg)` logs a line at `warning`, `collector '<name>': <msg>`, for what a collector that succeeds still has to say. At most 10 lines a run, each cut at 512 bytes. Past them, one line after the run says how many more were left out. |
| `exporter` | The exporter itself, read-only, for the `exporter` collector. `process(file)` reads the serving uhttpd's `/proc/<pid>/stat`, `status` or `limits`. `fds()` counts the descriptors it has open. `system(file)` reads `/proc/stat` or `/proc/self/auxv`. The instance's ledger counts, and each collector's samples, are written by the scrape itself while the `exporter` collector is selected (see [Metrics](metrics.md#scrape)). |

The collector fails with `NEED_MISSING`, without running, when the system lacks one of its needs (`nl80211`, `socket`). It fails with `PERMISSION_DENIED`, also without running, when the process:

- lacks a capability of `meta.capabilities`;
- may not read a config of `meta.configs`;
- may not read a file of `meta.proc_files` that is there. Read as anyone else, the file would look missing, and the collector would report nothing to observe.

A Unix socket it may not connect to (`EACCES`) is `PERMISSION_DENIED` too.

### Programs

- A program not in `meta.commands` is `COMMAND_NOT_ALLOWED`, and does not run.
- Its standard error is discarded. An exit status other than 0 is `COMMAND_FAILED`, with `data.status`. A program that cannot start is `COMMAND_FAILED` with `data.status` null.
- A collector's programs share a number of seconds per scrape: its section's `timeout`, else `meta.timeout`, else the main section's `exec_timeout` (5), at most 30. The shell counts whole seconds, so the programs take at most one second more.
- When the seconds are spent, the watchdog kills the program still running, with every process it started. That program is `COMMAND_TIMEOUT`, with `data.timed_out`. Any later `run` is `COMMAND_TIMEOUT` too, and does not run.
- `run_all` runs its programs one after another in one shell. Each costs a fork and an exec, where each `run` also costs a shell and a watchdog: a few milliseconds a program on a router. The programs share the seconds as `run`'s do. When the seconds are spent, the watchdog kills the program still running, as with `run`. The programs before it keep their Results, and those after it are `COMMAND_TIMEOUT` without running. A batch that cannot start is `COMMAND_FAILED` for each program.

## `out`

`out` is the recorder of `prometheus.exporter.exposition`:

| Call | Does |
| :--- | :--- |
| `out.gauge(name, help)`, `out.counter(name, help)`, `out.untyped(name, help)` | Declares a family, and returns `(labels, value)`, which records a sample and returns itself, so calls chain. |
| `out.batch(type, rows)` | Records families of one sample each. For each row `[ name, help, value, labels ]`, in order, it records what `out[type](name, help)(labels, value)` would, with less work. `labels` is optional, as for a writer: null, an object, or what `out.labels()` made. `type` is `'gauge'`, `'counter'` or `'untyped'`. |
| `out.labels(labels)` | Makes a label set once, for several samples to share. Pass it in place of the object. |
| `out.parse(text)` | Adds exposition text, which must be valid as a whole: a Result, `EXPOSITION_INVALID` otherwise. |

- `labels` is an object, null for none, or what `out.labels()` made. A label whose value is null is left out.
- A value that is not a number (null, an empty string, a word) is skipped. A string of digits, or of hex as in sysfs flags, is read as a number. `true` and `false` are 1 and 0.
- Names are made valid: each character the format does not allow becomes an underscore.
- A family declared twice with two types keeps the first type, and a warning is logged.
- A collector writes at most `max_samples` samples in all. The next one stops the collector: `out` throws, and throws again at each later sample. The collector fails with `SAMPLE_LIMIT`.
- `out` refuses anything that would make Prometheus refuse the whole scrape:
    - a label value or HELP text that is not valid UTF-8, or holds a NUL byte;
    - a family name that holds a NUL byte;
    - a label name Prometheus reserves: `__name__`, or any that starts with `__`, as written or once sanitized;
    - two label names that become one once sanitized (`if-name` and `if_name`);
    - labels given as a string of the collector's own.

    Such a sample stops the collector, as the one past `max_samples` does. The collector fails with `EXPOSITION_INVALID`, naming the family and the label.
- A family belongs to the first collector that writes it. A collector that writes another collector's family, or one of the exporter's own (`node_scrape_collector_*`, `ucode_prometheus_exporter_*`), fails with `FAMILY_CONFLICT`.

## Tests and packaging

Every collector has a unit test, `test/unit/prometheus/collectors/<module>_test.uc`, and a package. The package is either the base package, through `BASE_COLLECTORS`, or a `Collector` line of the package Makefile, which depends on what the collector's `needs` and `commands` call for. `test/integration/collectors_test.uc` checks both for every collector. See [How to package a collector](../how-to/developer/package-collector.md).

A unit test runs the collector with the devkit's `with_collector` (`prometheus.exporter.devkit.collector`). It fails the test when the collector touches a path, a socket or a program that its `meta` does not declare: see [Collector contract](collector-contract.md#in-the-tests) and [The devkit](devkit.md). A collector of another package is tested the same way, with `ucode-prometheus-exporter-devkit`: see [How to write a collector in your own package](../how-to/collector-package.md).

## See also

- [Tutorial: write your first collector](../tutorials/first-collector.md)
- [About nothing to observe](../explanation/nothing-to-observe.md)
- [About the architecture](../explanation/architecture.md)
