# Log Messages

The exporter logs to syslog as `prometheus-exporter`, facility `daemon`, each line at its own priority. Read it with `logread -e prometheus-exporter`.

| Priority | For |
| :--- | :--- |
| `err` | What stops it doing its job: an invalid configuration, a collector that does not load. |
| `warning` | What it does without: a collector that fails, which the scrape answers without; a path the jail cannot mount. |
| `info` | What it says of itself: how many collectors it serves, a directory it made, the settings it took over. |

A collector with nothing to observe logs nothing. Neither the password of basic auth nor its hash is ever logged.

---

## The handler

Logged by uhttpd's handler, with the pid of the uhttpd process.

| Message | Priority | When |
| :--- | :--- | :--- |
| `serving <n> collectors[, with basic auth][, gzip when asked]` | `info` | uhttpd loaded the handler. |
| `cannot load collector '<module>': <error>` | `err` | A collector module does not compile or import. It is left out. |
| `skipping collector: COLLECTOR_INVALID (<module>: <why>)` | `err` | A module's `meta` or `collect` is not valid. It is left out. |
| `/var/run/prometheus-exporter/uhttpd.conf is not one line of a user and a hash for /metrics: every request is denied` | `err` | Basic auth's file is there, and wrong. |
| `collector '<name>': <CODE (detail)>` | `warning` | A collector failed in a scrape. See [Error codes](error-codes.md). |
| `collector '<name>': <message>` | `warning` | A collector that succeeded said something with its `log` capability: textfile's `skipped <file>: <why>`. |
| `collector '<name>': '<family>' declared with two types; later samples dropped` | `warning` | A collector declared a family twice. |
| `'<family>' declared with two types by different collectors; later samples dropped` | `warning` | Two collectors declared a family with two types. |
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
