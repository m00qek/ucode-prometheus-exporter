# Collector Contract

What a collector may do, what the exporter enforces of it, and what breaking each rule costs. The exporter holds every collector to the contract alike, its own and those of other packages, in every way collectors run: the service's scrapes, `check`, the ubus object's `status` and the `prometheus-exporter` command.

The contract is for collectors that have bugs, not for hostile ones: see [About the security model](../explanation/security.md#buggy-not-hostile).

---

## What a collector may import

A collector module imports `prometheus_exporter.api`, the collector API, and nothing else:

```js
import { Result, errors, services, proc, exposition } from 'prometheus_exporter.api';
```

| Export | Names |
| :--- | :--- |
| `Result` | `ok`, `err`, `none`, `is`, `is_none`, `describe` |
| `errors` | `SOURCE_UNREADABLE`, `SOURCE_INVALID`, `CONFIG_INVALID`, the codes it fails with; `UBUS_CONNECT_FAILED`, `UBUS_CALL_FAILED`, `NL80211_FAILED`, `RTNL_FAILED`, `SOCKET_FAILED`, `COMMAND_NOT_ALLOWED`, `COMMAND_FAILED`, `COMMAND_TIMEOUT`, `SCRAPE_DEADLINE`, `EXPOSITION_INVALID`, those its capabilities return |
| `services` | `state`, `idle`, `unless_disabled`, `object_missing`; `ENABLED`, `DISABLED`, `NOT_INSTALLED`, `NOT_FOUND` |
| `proc` | `first_line`, `lines`, `each_line`, `fields`, `auxv`; `AT_PAGESZ`, `AT_CLKTCK` |
| `exposition` | `parse`, `format_value`, `sanitize` |

Each is described in [Collector interface](collector-interface.md#the-collector-api). These are the collector's semantic-versioning surface: what the API exports changes incompatibly only in a major version. The modules behind it are the core's, and change in any release. See [About versions](../explanation/versions.md#what-a-version-promises).

Refused, before the module is loaded:

- **Any other module.** `fs`, `ubus`, `uci`, `socket`, `rtnl`, `nl80211`, `uloop`: the capabilities of `meta.needs` do their work, under the exporter's guards. The core's modules, `prometheus_exporter.*`, including another collector's. Pure modules too, `math`, `struct` or `digest`: one would be a dependency the collector's package does not declare, and one more exception to judge; what collectors need of them belongs in the API, in a minor version.
- **Code loaded past the imports.** A call of `require`, `loadfile` or `loadstring`: `require('fs')` reaches `fs` as surely as an import.

The module's text is read for its imports without compiling it: comments, strings, templates and regular expressions are passed over. A collector is a single module; one that wants code of its own in another module has no way to, as every module of the collectors' directory is loaded as a collector.

| Where | Broken: |
| :--- | :--- |
| The loader, wherever collectors are loaded: the service, `check`, the ubus object, the command line | Not loaded; logged at `err`: `skipping collector: COLLECTOR_INVALID (<module>: imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs)` |
| `prometheus-exporter collector check` | A `FAIL` line, with the same text: `FAIL imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs` |
| The repository's tests | `test/unit/prometheus_exporter/imports_test.uc` holds every collector of `src/` to it. |

Each module refused is named with what to use instead: the capability, for a module of the system; the API, for the core's `result`, `errors`, `services`, `proc` and `exposition` (`take Result from prometheus_exporter.api`); `a collector imports prometheus_exporter.api alone`, for any other.

## What a collector may touch

| Of the system | Only |
| :--- | :--- |
| Files and directories | Procfs, sysfs, and what `meta.configs` and `meta.paths` declare. The jail has nothing else a collector would read: see [The jail](jail.md). |
| Unix sockets | Those in a directory of `meta.paths`. |
| Programs | Those of `meta.commands`. |
| ubus, uci, netlink | Through `deps.ubus`, `deps.uci` (the configs of `meta.configs`), `deps.rtnl`, `deps.nl80211`. |

Nothing it may read is writable.

### In the tests

`test/context.uc`'s `with_collector` runs a collector's test in the filesystem the service's jail gives it: the jail's mounts for its `meta`, and what every jail has (`jail.COMMON`: procfs, sysfs, the log's and ubus's sockets, ujail's devices and `/etc/resolv.conf`, the exporter's code, ucode's modules and libraries, the shell, the exporter's own config and state). Whatever the fs and socket mocks hold, an access outside them answers as in the jail:

| Access | Answers |
| :--- | :--- |
| `readfile`, `open` | `null` |
| `lsdir` | `null`; for a directory above a mount, such as `/etc`, the names of what is mounted under it |
| `stat`, `realpath` | `null`; for a directory above a mount, a directory |
| `glob` | What the pattern matches of the mounts only |
| `open` to write, of any path | `null`: the mounts are read-only |
| `deps.socket.unix_request` | `SOCKET_FAILED`, `connect(): No such file or directory` |
| `deps.exec.run` of a program not in `meta.commands` | `COMMAND_NOT_ALLOWED`, as everywhere |

Each such access is recorded, and once the collector has run the test fails, by `assert.fail()` (a failure, which a property test shrinks), not from inside the run, where the collector's error boundary would take it for a crash and a collector that falls back on a default would pass:

```
collector 'foo' read /etc/foo/state, which its meta does not declare.
In the service's jail that path does not exist: the read returns null, as it did here.
Declare it in meta.paths (or its directory: '/etc/foo'), or stop reading it.
Declared: /proc, /sys, /etc/config/foo
```

```
collector 'foo' connected to the socket /var/run/foo/foo.sock, which its meta does not declare.
In the service's jail that socket is not there: connect fails with 'No such file or directory', as it did here.
Declare its directory in meta.paths ('/var/run/foo'): the jail cannot mount a socket itself. Or stop connecting to it.
Declared: /proc, /sys
```

```
collector 'foo' ran 'false', which its meta.commands does not list.
The exporter refuses it, in the jail or not: run() returns COMMAND_NOT_ALLOWED without running it, as it did here. A test that expects the collector to fail may pass by accident.
List it in meta.commands, with 'exec' in meta.needs, or stop running it.
Declared commands: true
```

A `meta` the loader refuses, and text that is not valid exposition, fail the test the same way. `with_collector` asserts nothing of the collector's Result: the test does. A test's `outside_jail` names paths a collector looks for knowing the jail never has them, which the mocks then answer: chrony's command socket, for the server statistics it reads where it runs outside the jail.

## What a collector may do

| A collector may | Through |
| :--- | :--- |
| Read files, sockets, ubus objects, uci configs and netlink | The capabilities of `meta.needs`, in `collect`'s `deps`: see [Collector interface](collector-interface.md#needs). |
| Run programs | `deps.exec`, the programs of `meta.commands` only. |
| Write samples | `out`, the recorder: see [Collector interface](collector-interface.md#out). |
| Log what it could not read | `deps.log`, at `warning`. |
| Take its time | Up to its `budget`, and within the scrape's deadline. |
| Fail | `Result.err(code, details)`: what it wrote is served, and the scrape answers without the rest. |
| Have nothing to observe | `Result.none(reason)`: a success without samples. See [About nothing to observe](../explanation/nothing-to-observe.md). |

## What the exporter enforces

| Rule | Limit, by default | Set by | Broken: the error | Its breaker |
| :--- | :--- | :--- | :--- | :--- |
| The module is in strict mode: its first statement is `'use strict'`. | — | — | Not loaded; logged at `err`, `COLLECTOR_INVALID`. | — |
| It imports the collector API alone, and calls no `require`, `loadfile` nor `loadstring`. | — | — | Not loaded; logged at `err`, `COLLECTOR_INVALID`. See [What a collector may import](#what-a-collector-may-import). | — |
| Its top level only declares: it loads in time. | 5 s | — | Not loaded; logged at `err`, `collector '<module>' hung at load`. | — |
| `meta` and `collect` are valid. | — | — | Not loaded; logged at `err`, `COLLECTOR_INVALID`. | — |
| It returns a Result, without throwing. | — | — | `COLLECTOR_NO_RESULT`, `COLLECTOR_CRASHED`. | A failure |
| It returns within its budget. Its child process is killed then: a loop, a system call that never returns, a FIFO opened with no writer, all stop there. | 5 s, or its `timeout` and a second more | `collector_budget`, its section's `budget` | `COLLECTOR_CANCELLED`; none of its samples served. | Trips |
| It is done by the scrape's deadline: the scraper's timeout less half a second, and what writing the reply takes. | 9.5 s of Prometheus's 10 | the scraper, `scrape_timeout` | `SCRAPE_DEADLINE`: not run, or stopped; none of its samples served. | Unchanged |
| Its programs end in time. One still running is killed, with every process it started. | 5 s, in all, per scrape | `exec_timeout`, `meta.timeout`, its section's `timeout` | `COMMAND_TIMEOUT` | Trips |
| Its ubus calls are answered by its own limit (its budget, or the deadline). | as its budget | — | `UBUS_CALL_FAILED` | A failure |
| It writes at most its samples. The recorder stops it at the next. | 20,000 | `max_samples`, `meta.max_samples`, its section's `max_samples` | `SAMPLE_LIMIT`, saying how far it got; none of its samples served. | A failure |
| The collectors of a reply write at most its samples in all. The recorder stops the one that would go past them, and none starts once they are written. | 200,000 | `max_scrape_samples` | `SAMPLE_LIMIT`, saying how many were left; none of its samples served. | Unchanged |
| What it writes is what Prometheus takes: label values and HELP text in UTF-8, label names that stay apart once sanitized, labels that are an object or what `out.labels()` made. The recorder stops it at the first that is not. | — | — | `EXPOSITION_INVALID`, naming the family and the label; none of its samples served. | A failure |
| A family is one collector's: the first, in the reply's order, that writes it; the exporter's own collectors before those of other packages. | — | — | `FAMILY_CONFLICT`, naming the family's collector; none of its samples served. | A failure |
| It writes none of the exporter's own families: `node_scrape_collector_*`, and `ucode_prometheus_exporter_*` but for a collector that needs `exporter`. | — | — | `FAMILY_CONFLICT` | A failure |
| It takes no more memory than each of the service's processes may: past it, its own process ends. | A quarter of the RAM, at most 64 MB | `memory_limit` | `COLLECTOR_KILLED`; none of its samples served. | Trips |
| It leaves its process to the exporter: it never ends it, by `exit()` or a crash of a native module. | — | — | `COLLECTOR_KILLED` | Trips |
| It is not running when its scrape process dies (killed at uhttpd's timeout, or by the kernel out of memory). | — | — | The next scrape reads the dead one's progress file: `COLLECTOR_KILLED`, logged `collector '<name>' was running when a scrape process died`; the child left running is killed. | Trips |
| It reads only what the jail gives it, and runs at the service's priority. | nice 10 | — | What is not mounted is not there: `SOURCE_UNREADABLE`, `COMMAND_FAILED`. See [The jail](jail.md). | A failure |

Every collector runs in a process of its own, forked from the scrape's, one after the other: whatever its process does, the scrape's goes on with the next collector, in a new child when the last one was stopped or ended. See [About the architecture](../explanation/architecture.md#a-process-of-its-own).

## What breaking a rule costs

- **The collector, and nothing else.** The scrape answers on time with every other collector: their samples, `node_scrape_collector_success` 1. The broken one has `node_scrape_collector_success` 0.
- **Its samples.** A collector stopped, killed, over its `max_samples` or writing another's family has none of its samples served. One that fails by its own Result keeps what it wrote.
- **A line in the log**, at `warning`: `collector '<name>': <CODE> (<detail>)`. See [Log messages](log-messages.md).
- **A count**, `ucode_prometheus_exporter_collector_failures_total{collector,reason}`, from the `exporter` collector, since the service started.
- **Its breaker.** A collector stopped at its budget, killed, or whose program was killed at its timeout is quarantined at once; one that fails otherwise, after three scrapes in a row. It is left out for 1 scrape, then 2, 4 and up to 32, each trial doubling it, until a trial succeeds. See [About deadlines and circuit breakers](../explanation/deadlines-and-breakers.md#circuit-breakers).

A deadline that leaves a collector out, or stops it, is the scrape's time spent, not the collector's fault: its breaker stays as it was.

## What a collector may declare

| `meta` | Effect |
| :--- | :--- |
| `timeout` | The seconds its programs get, 1 to 30, unless its section says otherwise. Its budget is at least that and a second more. |
| `max_samples` | The samples it may write, 1 to 100,000, unless its section says otherwise: for one whose samples grow with what it reads, as nat_traffic's with the connection table (65,536). |
| `cost: 'heavy'` | Until the ledger has timed it, it runs after the other collectors it has not timed: so the first scrape after a restart does not spend their time on it. It changes the order alone. |

Until the ledger has timed them, as on the first scrape after a restart, the exporter's own collectors run before those of other packages.

## Check a module before installing it

```sh
prometheus-exporter collector check /tmp/my_collector.uc
```

It reads the module's text for strict mode and its imports, loads the module under the load timer, validates its `meta`, runs it on the device under the rules above, and says how long it took to load and to run, the samples it wrote and its families; then whether its text is valid exposition, each series once, and whether a family is one an installed collector or the exporter writes. A rule broken is a `FAIL` line, and exit status `1`. See [The prometheus-exporter command](command.md#collector-check).

## See also

- [Collector interface](collector-interface.md): `meta`, `deps` and `out`.
- [Tutorial: write your first collector](../tutorials/first-collector.md)
- [Error codes](error-codes.md)
