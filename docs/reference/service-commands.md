# Service Commands

The init script is `/etc/init.d/prometheus-exporter` (procd, `START=60`). Every action is also `service prometheus-exporter <action>`.

---

## Actions

| Action | What it does |
| :--- | :--- |
| `start` | Unless `option enabled '0'`: checks the configuration (`/usr/libexec/prometheus-exporter/check.uc --config`), sets up basic auth's file, makes the directories the collectors own and the state directory, and hands procd the uhttpd instance, in its jail. Refuses an invalid configuration, logging why at `err`. Waits for the listen interface: with no address on it yet, it logs `deferring start until listen interface <interface> becomes ready` and starts once the interface comes up. |
| `stop` | Stops the instances. |
| `restart` | `stop`, then `start`. The new instance starts without [state](jail.md#state). |
| `reload` | Checks the configuration. Invalid, it keeps the running instance and logs why; valid, it runs `start` again, and procd restarts the instance only if its command line, mounts or watched files changed. |
| `enable`, `disable` | Adds or removes the boot link `/etc/rc.d/S60prometheus-exporter`. |
| `enabled` | Exits 0 when the boot link is there. |
| `running` | Exits 0 when procd runs the service. |
| `status` | procd's state of the service, then one line: `disabled (option enabled in /etc/config/prometheus-exporter)`, or, while it runs, where it listens. See [`status`](#status). |
| `check` | Checks the configuration, lists every installed collector and runs a scrape, in the service's jail. See [`check`](#check). |

`option enabled` in the main section and the boot link are separate: `enabled '0'` stops the service whether or not it is enabled at boot.

## `status`

While the service runs:

```
running
listening on http://127.0.0.1:9100/metrics, gzip when asked, serving 16 collectors
```

| Part | Shown when |
| :--- | :--- |
| `listening on <url>, ...` | One URL per address uhttpd listens on: `http://` for HTTP, `https://` for HTTPS, `*:<port>` for every address. `nothing` when it listens on none. |
| `, basic auth` | uhttpd has basic auth's file: a scrape logs in. |
| `, gzip when asked` | `option compress` is on. |
| `, serving <n> collectors` | The installed collectors that are enabled. |

## `check`

`service prometheus-exporter check` runs `/usr/libexec/prometheus-exporter/check.uc`, the base package's, which needs no command line; `prometheus-exporter check` (see [The command](command.md#check)) runs the same. It prints a line per finding, then every installed collector, then the jail's mounts:

```
ok   main: HTTP on every address, port 9100, keepalive 70s, exec_timeout 5s, scrape_timeout 10s, collector_budget 5s, max_samples 20000, memory_limit 64 MB (a quarter of the RAM, at most 64), gzip when asked
ok   collectors: 17 installed collectors, their options valid
ok   scrape, in the service's jail: 17 of 17 collectors succeeded, 1 with nothing to observe
ok   scrape: wifi has nothing to observe: no wireless radios

collectors: 17 installed, 17 enabled
  conntrack (Connection tracking): section 'conntrack', enabled
      budget   5s # the main section's collector_budget
      needs    fs
  ...
  textfile (Text files): section 'textfile', enabled
      option   directory="/var/prometheus" # The directory of the *.prom files.
      budget   5s # the main section's collector_budget
      needs    fs log
      paths    /var/prometheus
      makes    /var/prometheus
      mounts   /var/prometheus
  ...

jail mounts:
  /bin/sh
  /etc/config/prometheus-exporter
  /var/prometheus
  /var/run/prometheus-exporter/timesync
```

### Findings

Each finding starts with `ok`, `warn` or `FAIL`. Only a `FAIL` makes `check` exit 1; it exits 0 otherwise.

| Finding | Level |
| :--- | :--- |
| `main: <listen summary>, exec_timeout <n>s, scrape_timeout <n>s, collector_budget <n>s, max_samples <n>, memory_limit <n> MB[ (a quarter of the RAM, at most 64)], gzip when asked` (or `no compression (option compress)`) | `ok` |
| `main: <CODE (detail)>`: an option of the main section the exporter does not take, or options that go together not set together | `FAIL` |
| `main: cert and key go together; with only cert, it serves HTTP` | `warn` |
| `main: <file> is missing; it serves HTTP until it is there` | `warn` |
| `main: <file> is missing; basic auth takes HTTPS only, so the service does not start until it is there` | `FAIL` |
| `collectors: <n> installed collectors, their options valid` | `ok` |
| `collector <name>, section '<module>': <CODE (detail)>`: an option of its section it does not take | `FAIL` |
| `section '<name>' names no installed collector; it is ignored` | `warn` |
| `an unnamed collector section is ignored: name it after its collector's module` | `warn` |
| `cannot load collector '<module>': ...` or `skipping collector: COLLECTOR_INVALID (...)`: a module the loader left out | `warn` |
| `jail: <collector>: <problem>`: a path or command the jail cannot give | `warn` |
| `jail: <collector>: <path> is not there; the service mounts it once it is` | `warn` |
| `scrape, in the service's jail: <n> of <m> collectors succeeded[, <k> with nothing to observe]` (or `outside the jail`, where ujail cannot run) | `ok`, or `warn` when one failed |
| `scrape: <collector>: <CODE (detail)>`: a collector that failed | `warn` |
| `scrape: <collector> has nothing to observe: <reason>` | `ok` |
| `service: <collector> is quarantined: <CODE (detail)>; the service tries it again at the next scrape` (or `in <n> scrapes`)`, or at once once restarted` | `warn` |
| `service: the scrape deadline left <collector> out in the last scrape` (or `<n> scrapes ago`, within the last 10) | `warn` |

The listen summary is `HTTP` or `HTTPS`, `on interface <name>` or `on every address`, the port and the keepalive, and `basic auth as user "<user>"` when basic auth is on. The password's hash is never shown.

### Collectors

One block per installed collector, enabled or not:

| Line | Content |
| :--- | :--- |
| `<name> (<title>): section '<module>', enabled` | Its name, title, the section that configures it, and whether it is enabled. |
| `option` | Each of its own options: `<name>=<value> # <help>`. |
| `timeout` | For a collector that runs programs: its seconds, and where they come from: `its section's option timeout`, `the collector's own (meta.timeout)` or `the main section's exec_timeout`. |
| `budget` | The seconds it may take before its circuit breaker trips, and where they come from: `its section's option budget`, `the main section's collector_budget` or `its timeout and a second more`. |
| `needs`, `configs` | Its `meta.needs` and `meta.configs`. |
| `paths`, `makes` | The paths it reads outside procfs and sysfs, and those the service makes for it. |
| `commands` | Each program it runs, `<name>=<path>`, or `(not found)`. |
| `mounts` | What the jail mounts for it, when it is enabled. |

The scrape `check` runs is in the service's own jail, with ujail, as the service's scrapes run (each collector in a process of its own, stopped at its budget, within `scrape_timeout`), with the committed configuration, and runs a collector the service quarantined all the same. Where ujail cannot run (not root, or a kernel or container that refuses it a namespace), it runs outside the jail, as root, with the same guards, and says `outside the jail`: a collector that works there and fails under procd lacks something in the jail; see [The jail](jail.md). The `service:` findings are what the service's own scrapes found, from its running instance's ledger: see [The jail](jail.md#the-ledger).

## procd

| Instance | Command | When |
| :--- | :--- | :--- |
| `instance1` | `/usr/sbin/uhttpd -f -c <auth file or /dev/null> -h /dev/null -S -D -o /metrics -O /usr/libexec/prometheus-exporter/handler.uc [-r prometheus-exporter] -k <keepalive> -t 60 -n 3 -N 10 [-C <cert> -K <key>] -p\|-s <address>:<port> ...` | While the service is enabled. `-s` (HTTPS) with `cert` and `key` both set and both there, `-p` (HTTP) otherwise. One `-p` or `-s` per address of the listen interface, IPv4 and IPv6, or the port alone for `*`. `-r` only with basic auth. `-t`, `-n` and `-N`: see [HTTP endpoint](http.md#connections). |
| `watch` | `/usr/libexec/prometheus-exporter/watch.uc <path>...` | While a path an enabled collector reads is not there. See [The jail](jail.md#missing-paths). |

Both are respawned by procd. The uhttpd instance runs in a jail: see [The jail](jail.md).

### Triggers

| Trigger | Action |
| :--- | :--- |
| A change of `/etc/config/prometheus-exporter`, of `/etc/config/prometheus-exporter-auth` (the ubus object's `set_password` sends its event itself), or of a config an enabled collector reads (`meta.configs`), applied by `reload_config` | `reload` |
| The listen interface going up or down, unless `listen_interface` is `*` | `reload` |
| The event `prometheus-exporter.path`, which the `watch` instance sends | `reload` |
| A change of a file procd watches for the instance: the configs it mounts, every collector module, basic auth's file, the TLS certificate and key | procd restarts the instance on `reload` |

### Package scripts

| Package | On install | On removal |
| :--- | :--- | :--- |
| `ucode-prometheus-exporter` | OpenWrt's defaults (run the uci-defaults script, enable and start the service), then reload rpcd; on an upgrade, restart a running service. | Reload rpcd. |
| A collector package | `reload` an enabled service, which restarts it with the collector. A failed reload fails no install. | The same, without the collector. |
| `luci-app-prometheus-exporter` | Clear LuCI's index and module caches, reload rpcd. | The same. |

None of the scripts runs while building an image (`$IPKG_INSTROOT` set).

## See also

- [The `prometheus-exporter` command](command.md): a scrape on the command line.
- [Log messages](log-messages.md): what the service logs.
- [How to troubleshoot](../how-to/troubleshoot.md).
