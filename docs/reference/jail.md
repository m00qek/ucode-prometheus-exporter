# The Jail

uhttpd, and with it the exporter, runs in procd's jail (ujail), named `prometheus-exporter`, with `no_new_privs`. The jail holds what the exporter needs, what its installed and enabled collectors declare, and nothing else. `src/prometheus_exporter/jail.uc` works out the mounts; `/usr/libexec/prometheus-exporter/jail.uc` prints them for the init script.

---

## What every jail has

| From | What |
| :--- | :--- |
| The jail's options | procfs, sysfs, the ubus socket, `/dev/log`. |
| The exporter | `/usr/lib/uhttpd_ucode.so`, `/lib/libubus.so*`, `/lib/libuci.so*`, `/usr/lib/libnl*.so*`, `/usr/lib/libz.so*`, `/usr/lib/ucode`, `/usr/share/ucode/prometheus_exporter`, `/usr/libexec/prometheus-exporter/handler.uc`; `/bin/sh`, whose `kill` a scrape uses to end a collector's process a dead scrape left running. |
| The configuration | `/etc/config/prometheus-exporter`. |
| HTTPS, with `cert` set | `cert`, `key`, `/lib/libustream-*.so*`, `/usr/lib/libustream-*.so*`. |
| Basic auth | Its file, `/var/run/prometheus-exporter/uhttpd.conf`. |
| The state | `/var/run/prometheus-exporter/state`, read-write. |

Every mount is read-only but the state. procd starts the instance at nice 10, with a data limit (`RLIMIT_DATA`) on each of its processes of `memory_limit` MB, or a quarter of the RAM, at most 64 MB: see [Collector contract](collector-contract.md).

`check`, the ubus object's `status` and `prometheus-exporter scrape` run their collectors in a jail of the same mounts, with ujail, at the same priority and data limit: `/usr/libexec/prometheus-exporter/trial.uc`, with the libraries of `/usr/lib/ucode/*.so` given one by one (ujail mounts what each needs), named `prometheus-exporter-trial`. Where ujail cannot run they run outside it.

## What a collector gets

For each installed collector that is enabled:

| Declared in `meta` | Mounted |
| :--- | :--- |
| `configs: [ 'dhcp' ]` | `/etc/config/dhcp`. |
| `exec` in `needs` | `/bin/sh`, which runs its programs. |
| `commands: [ 'nft' ]` | Each program, where `PATH` (`/usr/sbin:/usr/bin:/sbin:/bin`) finds it. ujail mounts its shared libraries along with it. |
| `optional_commands` | The same, where the program is installed; nothing, and no warning, where it is not. |
| `paths` | Each path: see [below](#paths). |

A disabled collector gets nothing. Nothing of `/etc/config` is there but the configs the enabled collectors name and the exporter's own. Which mounts each collector gets is in [Collectors](collectors.md) and in `check`.

## Paths

`meta.paths` lists what a collector reads outside procfs and sysfs:

| Entry | Mounted |
| :--- | :--- |
| `'/var/run/bmx7/json'` | That path. |
| `'{directory}'` | The value of the string option `directory`. |
| `{ path: '{directory}', owned: true }` | That path, which is the exporter's own: the service makes it, with its parents (mode 0755), when it is not there. |
| `(options, uci) => [ ... ]` | What the function returns for the collector's options and the configs it reads. |

A path is refused, with a warning, when it is not absolute, holds a space, a control or a glob character, is not plain (`//`, `.`, `..`, or a trailing `/`), or is one of the directories every service shares:

`/`, `/bin`, `/dev`, `/etc`, `/etc/config`, `/lib`, `/proc`, `/run`, `/sbin`, `/sys`, `/tmp`, `/tmp/run`, `/usr`, `/usr/bin`, `/usr/lib`, `/usr/sbin`, `/usr/share`, `/var`, `/var/run`.

ujail cannot mount a socket: a collector declares the socket's directory.

## Missing paths

A path that is not there when the service starts is left out of the mounts, and `check` warns of it. While one is missing, the service runs a second instance, `watch`, with the missing paths:

1. Every 5 seconds it looks for them.
2. Once one is there, it logs `<path> is there now: reloading to mount it` at `info` and sends procd the event `prometheus-exporter.path`.
3. The event reloads the service, which mounts the path and restarts uhttpd with it. The reload ends the `watch` instance, or starts it again for the paths still missing.
4. If procd does not take the event, it logs `cannot send procd prometheus-exporter.path; trying again in 60s` at `warning`.

A path the service owns is never missing: it makes it first.

## State

`/var/run/prometheus-exporter/state` is the one path the jail mounts read-write. It is on tmpfs, mode 0700, inside `/var/run/prometheus-exporter`, also 0700; `jail.uc --make` makes both when the service starts.

| | |
| :--- | :--- |
| Owner | A uhttpd instance: the handler names it when uhttpd loads it, before any request, by the pid and start time of that process. |
| Files | `<pid>-<start time>.<name>`, mode 0600, at most 32768 bytes each, written whole: to `<file>.new`, then renamed. |
| Lock | `<pid>-<start time>.lock`: every write holds an exclusive `flock()` of it; a read takes none. |
| Other instances' files | Removed when the handler loads. |
| Lifetime | Until the instance stops: a restart starts without state, a reload that keeps the instance keeps it. |
| Used for | Basic auth's cache, `<instance>.auth`: one digest of the last `Authorization` header let in. The ledger, `<instance>.scrape`: below. Each scrape's progress file, `<instance>.p<pid>_<start time>`, named by its process: a line `start <collector> <child pid>-<start time>` appended before each collector, `collected` once they are done, removed when the reply is written; one left by a dead process names the collector it was running, for the next scrape. The file a scrape's collectors' runs cross by, made with `mkstemp` and removed at once. |

### The ledger

`<instance>.scrape` is JSON, which every scrape of the handler reads when it starts and records itself in when it ends, re-reading it under the lock. `check` and the ubus object's `status` read the ledger of the instance that started last.

| Field | Content |
| :--- | :--- |
| `v` | 1, the ledger's version. A ledger of another version is read as empty. |
| `scrapes` | The scrapes the instance answered. |
| `k` | Seconds per sample of writing a reply, a moving average. |
| `c.<module>.d` | The collector's seconds, a moving average weighing the last run by 0.25. |
| `c.<module>.n` | The samples it wrote last. |
| `c.<module>.late` | The scrape that last left it out at the deadline. |
| `c.<module>.f` | Its failures in a row, while its breaker is closed. |
| `c.<module>.q` | The last scrape of its quarantine; absent while its breaker is closed. |
| `c.<module>.cd` | The cool-down of that quarantine, in scrapes: 1, 2, 4, 8, 16 or 32. |
| `c.<module>.why` | What tripped its breaker, as `CODE (detail)`. |
| `auth_failures` | The requests basic auth refused (401). |
| `c.<module>.fails` | Its failures by error code, `{ CODE: n }`, at most 8 codes; any other is counted as `OTHER`. |
| `c.<module>.to` | Its programs killed at their timeout. |
| `c.<module>.qn` | The times its breaker tripped. |
| `c.<module>.dl` | The times the deadline left it out, or killed its program. |

A collector no longer installed is dropped from it.

## Files the service writes

| Path | Mode | Written by | Mounted |
| :--- | :--- | :--- | :--- |
| `/var/run/prometheus-exporter/` | 0700 | `jail.uc --make`, `auth.uc` | No |
| `/var/run/prometheus-exporter/uhttpd.conf` | 0600 | `auth.uc`, at each start: one line, `/metrics:<user>:<hash>`; removed without basic auth | Read-only, with basic auth |
| `/var/run/prometheus-exporter/state/` | 0700 | `jail.uc --make` | Read-write |
| `/var/run/prometheus-exporter/timesync/` | 0755 | `jail.uc --make` (timesync's owned path), or the hotplug script | Read-only |
| `/var/run/prometheus-exporter/timesync/ntpd` | 0644 | `/etc/hotplug.d/ntp/90-prometheus-exporter`, on each event of busybox ntpd, outside the jail | With its directory |
| `/var/prometheus/` (textfile's `directory`) | 0755 | `jail.uc --make` | Read-only |

## Restarts

procd binds files into the jail. A file replaced by a new one, as `uci commit` replaces a config, stays the old one inside. So procd watches, for the uhttpd instance, the configs it mounts from `/etc/config`, every collector module and basic auth's file, and restarts the instance on `reload` when one changed.

## See also

- [Collector interface](collector-interface.md#meta): what a collector declares.
- [About the security model](../explanation/security.md)
