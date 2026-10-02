# Collector Contract

What a collector may do, what the exporter enforces of it, and what breaking each rule costs. The exporter holds every collector to the contract alike, its own and those of other packages, in every way collectors run: the service's scrapes, `check`, the ubus object's `status` and the `prometheus-exporter` command.

The contract is for collectors that have bugs, not for hostile ones: see [About the security model](../explanation/security.md#buggy-not-hostile).

---

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
| Its top level only declares: it loads in time. | 5 s | — | Not loaded; logged at `err`, `collector '<module>' hung at load`. | — |
| `meta` and `collect` are valid. | — | — | Not loaded; logged at `err`, `COLLECTOR_INVALID`. | — |
| It returns a Result, without throwing. | — | — | `COLLECTOR_NO_RESULT`, `COLLECTOR_CRASHED`. | A failure |
| It returns within its budget. Its child process is killed then: a loop, a system call that never returns, a FIFO opened with no writer, all stop there. | 5 s, or its `timeout` and a second more | `collector_budget`, its section's `budget` | `COLLECTOR_CANCELLED`; none of its samples served. | Trips |
| It is done by the scrape's deadline: the scraper's timeout less half a second, and what writing the reply takes. | 9.5 s of Prometheus's 10 | the scraper, `scrape_timeout` | `SCRAPE_DEADLINE`: not run, or stopped; none of its samples served. | Unchanged |
| Its programs end in time. One still running is killed, with every process it started. | 5 s, in all, per scrape | `exec_timeout`, `meta.timeout`, its section's `timeout` | `COMMAND_TIMEOUT` | Trips |
| Its ubus calls are answered by its own limit (its budget, or the deadline). | as its budget | — | `UBUS_CALL_FAILED` | A failure |
| It writes at most its samples. The recorder stops it at the next. | 20,000 | `max_samples`, `meta.max_samples`, its section's `max_samples` | `SAMPLE_LIMIT`, saying how far it got; none of its samples served. | A failure |
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

It loads the module under the load timer, validates its `meta`, runs it on the device under the rules above, and says how long it took to load and to run, the samples it wrote and its families; then whether its text is valid exposition, each series once, and whether a family is one an installed collector or the exporter writes. A rule broken is a `FAIL` line, and exit status `1`. See [The prometheus-exporter command](command.md#collector-check).

## See also

- [Collector interface](collector-interface.md): `meta`, `deps` and `out`.
- [Tutorial: write your first collector](../tutorials/first-collector.md)
- [Error codes](error-codes.md)
