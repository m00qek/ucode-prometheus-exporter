# Log Messages

The exporter logs to syslog as `prometheus-exporter`, facility `daemon`, each line at its own priority. Read it with `logread -e prometheus-exporter`.

| Priority | For |
| :--- | :--- |
| `err` | What stops it doing its job: an invalid configuration, a collector that does not load. |
| `warning` | What it does without: a collector that fails, which the scrape answers without; collectors the deadline left out; a quarantine; a path the jail cannot mount. |
| `notice` | A quarantined collector served again. |
| `info` | What it says of itself: how many collectors it serves, a directory it made, the settings it took over. |

A collector with nothing to observe logs nothing. Neither does a quarantined collector while it is left out. The exporter never logs basic auth's password, nor its hash.

---

## The handler

uhttpd's handler logs these, with the pid of the uhttpd process.

| Message | Priority | When |
| :--- | :--- | :--- |
| `serving <n> collectors[, with basic auth][, gzip when asked]` | `info` | uhttpd loaded the handler. |
| `cannot load collector '<module>': <error>` | `err` | A collector module does not compile or import, or loading it ended the process it was loaded in. It is left out. |
| `collector '<module>' hung at load: still loading after 5 s: stopped; it is left out` | `err` | A collector module's top level did not return within 5 s, in the child process where it is first loaded. |
| `skipping collector: COLLECTOR_IMPURE (<module>: its top level called <function>(), which <does>: ...)` | `err` | As it loaded, a collector module's top level called a function that blocks, ends or writes to the process, loads code, or changes its signals. The call was refused before it ran, in the child process where the module is first loaded, or in uhttpd's. The module is left out. See [Collector interface](collector-interface.md#the-top-level). |
| `skipping collector: COLLECTOR_IMPURE (<module>: its top level changed the global scope, <name>, ...: ...)` | `err` | A collector module's top level wrote over, added or removed these names of the global scope. The change would have stayed in uhttpd for every scrape. The names are put back as they were, and the module is left out. |
| `skipping collector: COLLECTOR_IMPURE (<module>: its top level wrote over what the collector API exports, which no collector may change: object value is immutable)` | `err` | A collector module's top level wrote over `Result`, `errors`, `services`, `proc` or `exposition`, or a Result's prototype. Every collector shares these, and ucode keeps them constant. The module is left out. |
| `skipping collector: COLLECTOR_INVALID (<module>: <why>)` | `err` | A module's `meta` or `collect` is not valid; or it is not in strict mode (`not in strict mode: its first statement must be 'use strict'`); or it imports a module other than the collector API, or loads code past its imports (`imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs`; see [Collector contract](collector-contract.md#what-a-collector-may-import)). It is left out. |
| `checking again what changed since it was checked, as in an upgrade: <module> ...` | `info` | A collector module's file changed between its check in the probe's child and its load in uhttpd. This happens when an upgrade of several packages writes the next package while the service starts. The module is checked and loaded again, alone. |
| `skipping collector: <module>: not what it was when it was checked, in a process of its own, 3 times: is it being upgraded?` | `err` | The module changed at each of three checks. It is left out until the next reload. |
| `native module '<name>' did not load in a process of its own: <error>; each scrape loads it where it needs it` | `warning` | uhttpd loads ubus, rtnl, nl80211 and zlib when it starts. This one failed or crashed as it loaded in the probe's child, so uhttpd does not load it. A scrape's child loads it where a collector needs it, and a crash there costs only that collector (`COLLECTOR_KILLED`). Without zlib, replies are sent plain. |
| `asked to stop (signal <n>) while it loaded the collectors: stopping` | `notice` | procd stopped the instance while it loaded its collectors, as a reload between the packages of an upgrade does. The instance ends at once, as the signal would have ended it, and procd starts the next. |
| `/var/run/prometheus-exporter/uhttpd.conf is not one line of a user and a hash for /metrics: every request is denied` | `err` | Basic auth's file is there, and wrong. |
| `/var/run/prometheus-exporter/uhttpd.conf is not there, and the config sets basic auth (auth_user): every request is denied` | `err` | uhttpd started without basic auth's file, though `auth_user` is set: procd started it again after the file was removed. `service prometheus-exporter restart` writes the file. |
| `collector '<name>': <CODE (detail)>` | `warning` | A collector failed in a scrape, with the code it returned, or with the code the exporter stopped it with (`COLLECTOR_CANCELLED`, `COLLECTOR_KILLED`, `SAMPLE_LIMIT`, `EXPOSITION_INVALID`, `FAMILY_CONFLICT`). Not for `SCRAPE_DEADLINE`, which the scrape's own line reports. See [Error codes](error-codes.md) and [Collector contract](collector-contract.md). |
| `collector '<name>' was running when a scrape process died` | `warning` | A scrape found the progress file of a scrape process that died while this collector ran. The collector is quarantined, and the child process it ran in is killed. |
| `cannot fork a process to run the collectors in; running the collectors in the scrape's own process` | `warning` | The system could not fork (out of processes or memory). The scrape ran its collectors in its own process, where nothing can stop them midway. |
| `cannot make the file the collectors' runs cross by, in <directory>; running the collectors in the scrape's own process` | `warning` | The state's directory (`/tmp` outside the service) is full or not writable, so it could not take a temporary file. The scrape ran its collectors in its own process, where nothing can stop them midway. |
| `scrape deadline: <n> collector[s] not served in its <seconds> s: <name>, ...` | `warning` | The scrape's deadline left these collectors out, or killed their programs. One line per scrape. See [HTTP endpoint](http.md#deadline). |
| `collector '<name>' quarantined for <n> scrape[s]: <CODE (detail)>` | `warning` | Its circuit breaker tripped, on a program killed at its timeout, on `COLLECTOR_OVERRUN` (over its budget), or on a third failure in a row. Or its trial failed. |
| `collector '<name>' served again: its trial succeeded` | `notice` | Its circuit breaker closed. |
| `collector '<name>': <message>` | `warning` | A collector that succeeded said something with its `log` capability. For example textfile's `skipped <file>: <why>`, as `skipped /var/prometheus/x.prom: is not a regular file (fifo): not read`. |
| `collector '<name>': <n> more line[s] of its log left out` | `warning` | A collector's run logged more than 10 lines with its `log` capability. The first 10 were logged, each cut at 512 bytes, and this line once the run was over. |
| `collector '<name>': '<family>' declared with two types; later samples dropped` | `warning` | A collector declared a family twice. |
| `the process running the collectors ran past the scrape's deadline, past the limits it gave: stopped there, the rest left out` | `warning` | Something a collector did went wrong in the child process that runs the collectors. That process gave a collector a limit past the scrape's deadline, or none, or went on past the deadline with no collector started. The scrape stopped it at the deadline itself, served the runs it had finished, and left the rest out with `SCRAPE_DEADLINE`. |
| `the processes forked to run the collectors in ended twice before running one; not run: <name>, ...` | `warning` | Two child processes in a row ended before they ran a collector. The collectors left fail with `COLLECTOR_NOT_RUN`, and their breakers stay as they were. |
| `asked to stop (signal <n>) while it ran the collectors: stopping` | `notice` | The scrape's process was asked to stop (SIGTERM or SIGINT) while its collectors ran. It stopped their child process and ended at once, as the signal would have ended it, without a reply and without blaming a collector. |
| `the scrape could not be recorded in the instance's state: its ledger is as the last scrape left it` | `warning` | The state's directory could not be written. The next scrape orders, times and quarantines the collectors by the ledger as it was. |
| `main: <CODE (detail)>` | `err` | A scrape read a main section it does not accept, and used the defaults. |

The handler logs through ucode-mod-log, at each message's own priority. It does not log to standard error, which procd would log at `err` whatever the message.

## The init script

| Message | Priority | When |
| :--- | :--- | :--- |
| `FAIL main: ...`, `FAIL collector ...`, the lines of `check --config` | `err` | `start` or `reload` found the configuration invalid. Also on standard error. |
| `invalid configuration, not starting` | `err` | `start` refused it. Also on standard error. |
| `invalid configuration, keeping the running instance` | `err` | `reload` refused it. Also on standard error. |
| `deferring start until listen interface <interface> becomes ready` | `info` | The listen interface has no address yet. |
| `<CODE (detail)>`, then `cannot set up basic auth, not starting` | `err` | Basic auth's file could not be written or removed. |
| `basic auth takes HTTPS only, and <cert> or <key> is missing: not starting` | `err` | Basic auth is on, and a TLS file is not there. |
| `made <path>` | `info` | It made a directory a collector owns, such as `/var/prometheus`. |
| `cannot make <path>: <error>` | `err` | It could not make one, or the state directory. |
| `<collector>: <problem>` | `warning` | A path or a program the jail cannot give a collector: `command <name> is not on /usr/sbin:/usr/bin:/sbin:/bin`, `<path> is too broad to mount for one collector`, `its paths are not known: ...`, `a paths function failed: ...`. |
| `ubus ACL of prometheus-exporter: <object> <methods>, ...` | `info` | It wrote the service's ubus ACL, which changed, and had ubusd read it again. |
| `ubusd (pid <pid>) crashed as it read its ACLs again, and procd starts it again` | `err` | Having ubusd read the ACL crashed it: see [When ubusd crashes](jail.md#when-ubusd-crashes). |
| `restarted <service>, which does not register on ubus again by itself` | `info` | After that crash: rpcd, dnsmasq or odhcpd, whose objects ubusd lost. |
| `cannot restart <service>, which does not register on ubus again by itself` | `err` | After that crash, its init script is not there, or failed. |
| `not on ubus again: <objects>: restart the services that register them, or reboot` | `err` | After that crash, objects that were on ubus are still missing 10 s after the restarts. |
| `ubusd did not start again within 10 s: reboot` | `err` | After that crash, procd did not start ubusd again. |
| `ubusd is not running`, `cannot signal ubusd (pid <pid>)` | `err` | It could not have ubusd read the ACL. |

## The `watch` instance

| Message | Priority | When |
| :--- | :--- | :--- |
| `<path>[, <path>] is there now: reloading to mount it` | `info` | A missing path appeared. |
| `cannot send procd prometheus-exporter.path; trying again in 60s` | `warning` | procd did not take the event. |

## Installation

A uci-defaults script takes over a feed exporter's settings, and moves basic auth's hash out of the place 0.2.0 kept it. It logs at `info`, once, when the package is installed or upgraded:

| Message | When |
| :--- | :--- |
| `imported from /etc/config/<old>: <option>=<value>, ..., collector <module>` | It took over these settings. It says `nothing it changed from the defaults` when there was nothing to take over. |
| `<old>: option <option>: expected <what>, got <value>; left at the default` | A value this exporter does not accept. |
| `<old>: collector <module>, option <option>: expected <what>, got <value>; left at its default` | A value of a collector section that the collector does not accept. |
| `<old>: collector <module> has no option <option>; left out` | An option of a collector section that the installed collector does not have. |
| `<old>: collector <module> is not installed, and <option> is not an option it is known to have; left out` | An option of a collector section whose collector is not installed yet. The option is neither one the feed's ucode exporter had for that collector (wifi's `stations`) nor one of the core's (`enabled`, `budget`, `max_samples`). |
| `/etc/config/prometheus-exporter is not as the package ships it: nothing imported from /etc/config/<old>` | The config had been changed already. |
| `auth_password moved from /etc/config/prometheus-exporter to /etc/config/prometheus-exporter-auth` | An upgrade from 0.2.0 found the hash of basic auth's password where 0.2.0 kept it, and moved it to where the exporter reads it now. |
| `auth_password removed from /etc/config/prometheus-exporter: /etc/config/prometheus-exporter-auth has one already, which is kept` | The same, when a hash was already saved apart. |
| `/etc/config/prometheus-exporter-auth is not there: auth_password left in /etc/config/prometheus-exporter, where it is not read; set it again` | The hash's config was removed: save the password again (`set_password`). |

See [How to move from the feed's exporters](../how-to/migrate-from-feed.md).
