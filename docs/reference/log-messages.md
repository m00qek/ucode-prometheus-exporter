# Log Messages

The exporter logs to syslog as `prometheus-exporter`, facility `daemon`, each line at its own priority. Read it with `logread -e prometheus-exporter`.

| Priority | For |
| :--- | :--- |
| `err` | What stops it doing its job: an invalid configuration, a collector that does not load. |
| `warning` | What it does without: a collector that fails, which the scrape answers without; collectors the deadline left out; a quarantine; a path the jail cannot mount. |
| `notice` | A quarantined collector served again. |
| `info` | What it says of itself: how many collectors it serves, a directory it made, the settings it took over. |

A collector with nothing to observe logs nothing, nor does a quarantined one while it is left out. Neither the password of basic auth nor its hash is ever logged.

---

## The handler

Logged by uhttpd's handler, with the pid of the uhttpd process.

| Message | Priority | When |
| :--- | :--- | :--- |
| `serving <n> collectors[, with basic auth][, gzip when asked]` | `info` | uhttpd loaded the handler. |
| `cannot load collector '<module>': <error>` | `err` | A collector module does not compile or import, or its loading ended the process it loaded in. It is left out. |
| `collector '<module>' hung at load: still loading after 5 s: stopped; it is left out` | `err` | A collector module's top level did not return in 5 s, in the child process it is first loaded in. |
| `skipping collector: COLLECTOR_INVALID (<module>: <why>)` | `err` | A module's `meta` or `collect` is not valid, it is not in strict mode (`not in strict mode: its first statement must be 'use strict'`), or it imports a module other than the collector API, or loads code past its imports (`imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs`; see [Collector contract](collector-contract.md#what-a-collector-may-import)). It is left out. |
| `/var/run/prometheus-exporter/uhttpd.conf is not one line of a user and a hash for /metrics: every request is denied` | `err` | Basic auth's file is there, and wrong. |
| `collector '<name>': <CODE (detail)>` | `warning` | A collector failed in a scrape, but for `SCRAPE_DEADLINE`, which the scrape's line says: as it returned it, or as the exporter stopped it (`COLLECTOR_CANCELLED`, `COLLECTOR_KILLED`, `SAMPLE_LIMIT`, `EXPOSITION_INVALID`, `FAMILY_CONFLICT`). See [Error codes](error-codes.md) and [Collector contract](collector-contract.md). |
| `collector '<name>' was running when a scrape process died` | `warning` | A scrape found the progress file of a scrape process that died while this collector ran. It is quarantined, and the child process it ran in is killed. |
| `cannot fork a process to run the collectors in; running the collectors in the scrape's own process` | `warning` | The system could not fork (out of processes or memory): the scrape ran its collectors in its own process, which nothing can stop midway. |
| `cannot make the file the collectors' runs cross by, in <directory>; running the collectors in the scrape's own process` | `warning` | The state's directory (`/tmp` outside the service) could not take a temporary file, full or not writable: the scrape ran its collectors in its own process, which nothing can stop midway. |
| `scrape deadline: <n> collector[s] not served in its <seconds> s: <name>, ...` | `warning` | The scrape's deadline left these collectors out, or killed their programs: one line per scrape. See [HTTP endpoint](http.md#deadline). |
| `collector '<name>' quarantined for <n> scrape[s]: <CODE (detail)>` | `warning` | Its circuit breaker tripped: a program killed at its timeout, `COLLECTOR_OVERRUN` (over its budget), or a third failure in a row; or its trial failed. |
| `collector '<name>' served again: its trial succeeded` | `notice` | Its circuit breaker closed. |
| `collector '<name>': <message>` | `warning` | A collector that succeeded said something with its `log` capability: textfile's `skipped <file>: <why>`, as `skipped /var/prometheus/x.prom: is not a regular file (fifo): not read`. |
| `collector '<name>': <n> more line[s] of its log left out` | `warning` | A collector's run logged more than 10 lines with its `log` capability: the first 10 were logged, each cut at 512 bytes, and this once the run was over. |
| `collector '<name>': '<family>' declared with two types; later samples dropped` | `warning` | A collector declared a family twice. |
| `the processes forked to run the collectors in ended twice before running one; not run: <name>, ...` | `warning` | Two child processes in a row ended before they ran a collector: the collectors left fail with `COLLECTOR_NOT_RUN`, their breakers as they were. |
| `the scrape could not be recorded in the instance's state: its ledger is as the last scrape left it` | `warning` | The state's directory could not be written: the next scrape orders, times and quarantines the collectors by the ledger as it was. |
| `main: <CODE (detail)>` | `err` | A scrape read a main section it does not take, and used the defaults. |

## The init script

| Message | Priority | When |
| :--- | :--- | :--- |
| `FAIL main: ...`, `FAIL collector ...`, the lines of `check --config` | `err` | `start` or `reload` found the configuration invalid. Also on standard error. |
| `invalid configuration, not starting` | `err` | `start` refused it. Also on standard error. |
| `invalid configuration, keeping the running instance` | `err` | `reload` refused it. Also on standard error. |
| `deferring start until listen interface <interface> becomes ready` | `info` | The listen interface has no address yet. |
| `<CODE (detail)>`, then `cannot set up basic auth, not starting` | `err` | Basic auth's file could not be written or removed. |
| `basic auth takes HTTPS only, and <cert> or <key> is missing: not starting` | `err` | Basic auth is on and a TLS file is not there. |
| `made <path>` | `info` | It made a directory a collector owns, such as `/var/prometheus`. |
| `cannot make <path>: <error>` | `err` | It could not make one, or the state directory. |
| `<collector>: <problem>` | `warning` | A path or a program the jail cannot give a collector: `command <name> is not on /usr/sbin:/usr/bin:/sbin:/bin`, `<path> is too broad to mount for one collector`, `its paths are not known: ...`, `a paths function failed: ...`. |

## The `watch` instance

| Message | Priority | When |
| :--- | :--- | :--- |
| `<path>[, <path>] is there now: reloading to mount it` | `info` | A missing path appeared. |
| `cannot send procd prometheus-exporter.path; trying again in 60s` | `warning` | procd did not take the event. |

## Installation

The uci-defaults script that takes over a feed exporter's settings logs at `info`, once, when the package is installed:

| Message | When |
| :--- | :--- |
| `imported from /etc/config/<old>: <option>=<value>, ..., collector <module>` | It took these. `nothing it changed from the defaults` when there was nothing to take. |
| `<old>: option <option>: expected <what>, got <value>; left at the default` | A value this exporter does not take. |
| `/etc/config/prometheus-exporter is not as the package ships it: nothing imported from /etc/config/<old>` | The config had been changed already. |

See [How to move from the feed's exporters](../how-to/migrate-from-feed.md).
