# The Jail

uhttpd, and with it the exporter, runs in procd's jail (ujail), named `prometheus-exporter`, with `no_new_privs`, as the user and group `prometheus-exporter`, never root. The jail holds what the exporter needs, what its installed and enabled collectors declare, and nothing else, and the user may do only what they declare besides: see [The service's user](#the-services-user). `src/prometheus/exporter/jail.uc` works out the mounts, and `src/prometheus/exporter/privileges.uc` what the user is granted; `/usr/libexec/prometheus-exporter/jail.uc` prints the mounts for the init script, and grants the rest.

---

## What every jail has

| From | What |
| :--- | :--- |
| The jail's options | procfs, sysfs, `/dev/log`. |
| The exporter (`jail.uc`, before the collectors' mounts) | `/usr/lib/uhttpd_ucode.so`, `/lib/libubus.so*`, `/lib/libuci.so*`, `/usr/lib/libnl*.so*`, `/usr/lib/libz.so*`, `/usr/lib/ucode`, `/usr/share/ucode/prometheus`, `/usr/libexec/prometheus-exporter/handler.uc`; `/bin/sh`, whose `kill` a scrape uses to end a collector's process a dead scrape left running. |
| The configuration | `/etc/config/prometheus-exporter`. |
| HTTPS, with `cert` and `key` there, and copied | Their copies, `/var/run/prometheus-exporter/tls.crt` and `tls.key`; `/lib/libustream-*.so*`, `/usr/lib/libustream-*.so*`. |
| Basic auth | Its file, `/var/run/prometheus-exporter/uhttpd.conf`. |
| The state | `/var/run/prometheus-exporter/state`, read-write. |

Every mount is read-only but the state. The ubus socket is not among them: see [What a collector gets](#what-a-collector-gets). procd starts the instance at nice 10, with a data limit (`RLIMIT_DATA`) on each of its processes of `memory_limit` MB, or a quarter of the RAM, at most 64 MB: see [Collector contract](collector-contract.md).

`check`, the ubus object's `status` and `prometheus-exporter scrape` run their collectors in a jail of the same mounts, with ujail, at the same priority and data limit, with ubus (ujail's `-u`) only when the service's jail has it: `/usr/libexec/prometheus-exporter/trial.uc`, with the libraries of `/usr/lib/ucode/*.so` given one by one (ujail mounts what each needs), named `prometheus-exporter-trial`. Where ujail cannot run they run outside it.

The libraries of ucode's modules are mounted by glob (`/usr/lib/ucode/*.so`, libubus, …): ujail stages the libraries a library it is given needs, but not those of a directory's files.

## What a collector gets

For each installed collector that is enabled:

| Declared in `meta` | Mounted |
| :--- | :--- |
| `configs: [ 'dhcp' ]` | `/etc/config/dhcp`. |
| `ubus` in `needs` | The ubus socket, `/var/run/ubus/ubus.sock`, by the jail's `ubus` option: `jail.uc` names it, and the init script gives the jail the option for it. While no enabled collector needs ubus, the jail has no ubus. |
| `exec` in `needs` | `/bin/sh`, which runs its programs. |
| `commands: [ 'nft' ]` | Each program, where `PATH` (`/usr/sbin:/usr/bin:/sbin:/bin`) finds it. ujail mounts its shared libraries along with it. |
| `optional_commands` | The same, where the program is installed; nothing, and no warning, where it is not. |
| `paths` | Each path: see [below](#paths). |

A disabled collector gets nothing. Nothing of `/etc/config` is there but the configs the enabled collectors name and the exporter's own. Which mounts each collector gets is in [Collectors](collectors.md) and in `check`.

Some declarations are shaped by the jail. modemmanager gets the directory `/var/run/dbus`, not the system bus socket in it: dbus makes the socket anew each time it starts, and a bind mount of the old one would go stale. chrony and timesync run `chronyc -u root`: OpenWrt builds chrony to drop root for the `chrony` user, whom the jail, without `/etc/passwd`, cannot look up. timesync gets the directory of busybox ntpd's last event, not the file, which the hotplug script renames into it.

## The service's user {#the-services-user}

The package makes the user and group `prometheus-exporter` (its `USERID`, at the first free id from 32768), on install and on upgrade. procd has ujail run uhttpd as them (`-U`, `-G`), with no new privileges (`-c`), and with the capabilities file `/var/run/prometheus-exporter/capabilities.json` (`-C`). As anyone but root, the process reads only what the files' modes let it, ubusd holds it to an ACL, and it has no capability it is not given. The init script refuses to start without the user, saying so at `err`.

When the service starts, `jail.uc --make`, as root, grants the user what the installed and enabled collectors declare, and takes back what the installed collectors that are not enabled declare, unless an enabled one declares it too:

| Declared in `meta` | Granted |
| :--- | :--- |
| `ubus: { dnsmasq: [ 'metrics' ] }` | The call, in the service's [ubus ACL](#the-ubus-acl). Taken back: the ACL is written anew. |
| `capabilities: [ 'CAP_NET_ADMIN' ]` | The capability, in every set of the capabilities file (bounding, effective, permitted, inheritable, ambient), so the programs the jail runs have it too. |
| `groups: [ 'unbound' ]` | The user's membership of the group, in `/etc/group`, under OpenWrt's lock (`/var/lock/passwd`), when the group is there. Taken back: the membership is removed. |
| `proc_files: [ '/proc/net/nf_conntrack' ]` | Read access for the group: the file's group is `prometheus-exporter`, and its group bits `r--`. Taken back: its group is root's again. |
| `configs: [ 'dhcp' ]`, and the exporter's own config | The same, for `/etc/config/<config>`. |

What the enabled collectors declare now:

| Collector | Granted |
| :--- | :--- |
| `nft-counters` | `CAP_NET_ADMIN`: nftables answers a netlink dump to it alone. |
| `nat_traffic` | Reading `/proc/net/nf_conntrack`, `r--r-----` root's. |
| `unbound` | The group `unbound`: unbound's control socket is `srw-rw----` `unbound:unbound`. |
| Those that read a config (`chrony`, `dhcp_leases`, `uci_dhcp_host`, ...) | Reading it: OpenWrt's configs are mostly root's alone (0600). |
| Those that call ubus | Their calls: see [Collectors](collectors.md) (**Calls over ubus**). |

And the service's own: `CAP_NET_BIND_SERVICE` while `listen_port` is under 1024. No collector may declare a capability but `CAP_NET_ADMIN` and `CAP_NET_RAW`: not `CAP_DAC_READ_SEARCH` or `CAP_DAC_OVERRIDE`, which would read past the jail's mounts (a file opened by handle) or write `/proc` (the jail's procfs is writable).

`uci commit` replaces a config with a file of root's group (it keeps the mode): the reload it triggers grants it again before procd restarts uhttpd, which until then reads the file it mounted. `/proc` files are the kernel's: a module loaded again gives them back to root.

`check`, the ubus object's `status` and `prometheus-exporter scrape` run their collectors in a jail of the same user, with no new privileges and the capabilities file the service wrote: what the service granted when it started. While the service is stopped, they have no capability and no ACL.

What stays root's: the init script and `jail.uc`, rpcd's ubus object, and the `watch` instance (see [Missing paths](#missing-paths)), unjailed, which sends procd the event that reloads the service: sending an event takes procd's `service event`, which would let whoever calls it send any.

### The ubus ACL {#the-ubus-acl}

ubusd reads its ACLs from `/usr/share/acl.d`: the package installs there `prometheus-exporter.json`, a link to `/var/run/prometheus-exporter.acl.json`, which `jail.uc --make` writes when the service starts, for the user `prometheus-exporter`, of the calls the enabled collectors declare (their `meta.ubus`, for their options), and has ubusd read again (SIGHUP) when it changed. It is root's, mode 0644, outside the service's run directory, which only root enters: ubusd runs as its own user. Stopped or disabled, the service removes it, and the link points nowhere.

It is written for the enabled collectors, not installed with the packages for all of them, so a call is allowed only while a collector that declares it is enabled, with the options that call for it: wireguard's `peer_names` for the ubus object's `wireguard_peers`. ubusd's ACL names objects and methods, never arguments, so no collector declares a call that reads what its caller names or answers a secret, as rpcd's `file read` and `uci get`, netifd's `network.wireless status` and procd's `service list` do: the service's own ubus object asks those as root, for the fields the collectors read (see [ubus object](ubus.md#for-the-collectors)). Every call the ACL can allow is in [About the security model](../explanation/security.md#what-the-services-user-reaches-over-ubus).

A call the ACL does not allow, ubusd refuses: `Permission denied` for a method of an object the user may call other methods of, `Not found` for an object it may call nothing of, which it does not list either. So the ACL always allows `system board`, the canary: a collector whose object is not found asks for it, and while it is not there either, ubusd has not loaded the ACL, and the call is `PERMISSION_DENIED`, never nothing to observe.

### What fails, and how

Nothing the user lacks is taken for nothing to observe. A collector fails `PERMISSION_DENIED`, saying what and what grants it, when its process lacks a capability it declares, may not read a config or `/proc` file it declares, may not connect to a Unix socket (`EACCES`), or ubusd refuses a call; a call its `meta.ubus` does not list is refused before ubusd sees it, `UBUS_NOT_ALLOWED`. See [Error codes](error-codes.md). A reload grants again what was taken away under the service.

## Paths

`meta.paths` lists what a collector reads outside procfs and sysfs:

| Entry | Mounted |
| :--- | :--- |
| `'/var/run/bmx7/json'` | That path. |
| `'{directory}'` | The value of the string option `directory`. |
| `{ path: '{directory}', owned: true }` | That path, which is the exporter's own: the service makes it, with its parents (mode 0755), when it is not there. It must be under `/var`, `/tmp` or `/etc/prometheus-exporter`: see [below](#owned-paths). |
| `(options, uci) => [ ... ]` | What the function returns for the collector's options and the configs it reads. |

A path is refused, with a warning, when it is not absolute, holds a space, a control or a glob character, is not plain (`//`, `.`, `..`, or a trailing `/`), or is one of the directories every service shares:

`/`, `/bin`, `/dev`, `/etc`, `/etc/config`, `/lib`, `/proc`, `/run`, `/sbin`, `/sys`, `/tmp`, `/tmp/run`, `/usr`, `/usr/bin`, `/usr/lib`, `/usr/sbin`, `/usr/share`, `/var`, `/var/run`.

ujail cannot mount a socket: a collector declares the socket's directory.

### Owned paths {#owned-paths}

The service makes an owned path as root, and mounts it, so it takes one only below these, and refuses any other with a warning, neither made nor mounted:

| Under | Why |
| :--- | :--- |
| `/var`, `/tmp` | tmpfs on OpenWrt (`/var` is `/tmp`): what a script writes there often does not wear the flash. |
| `/etc/prometheus-exporter` | The exporter's own, on flash: for files that must outlive a reboot. |

An option that names one, as textfile's `directory`, has the datatype `owned_directory`, which takes the same: the configuration is refused with `OWNED_DIRECTORY` (see [UCI configuration](uci-config.md#problems)) before the service makes anything.

## Missing paths

A path that is not there when the service starts is left out of the mounts, and `check` warns of it. While one is missing, the service runs a second instance, `watch`, with the missing paths:

1. Every 5 seconds it looks for them.
2. Once one is there, it logs `<path> is there now: reloading to mount it` at `info` and sends procd the event `prometheus-exporter.path`.
3. The event reloads the service, which mounts the path and restarts uhttpd with it. The reload ends the `watch` instance, or starts it again for the paths still missing.
4. If procd does not take the event, it logs `cannot send procd prometheus-exporter.path; trying again in 60s` at `warning`.

A path the service owns is never missing: it makes it first.

## State

`/var/run/prometheus-exporter/state` is the one path the jail mounts read-write. It is on tmpfs, mode 0700, the service's user's, inside `/var/run/prometheus-exporter`, 0700 and root's; `jail.uc --make` makes both when the service starts.

| | |
| :--- | :--- |
| Owner | A uhttpd instance: the handler names it when uhttpd loads it, before any request, by the pid and start time of that process. |
| Files | `<pid>-<start time>.<name>`, mode 0600, at most 32768 bytes each, written whole: to `<file>.new`, then renamed. |
| Lock | `<pid>-<start time>.lock`: every write holds an exclusive `flock()` of it; a read takes none. |
| Read by root | `check` and the ubus object's `status`, nothing else of the object, read the ledger, as root: only a regular file of the state's owner with one link and at most 32768 bytes, never a link, a FIFO or a device in its place, and without blocking. See [About the implementation](../explanation/internals.md#ucode). |
| Other instances' files | Removed when the handler loads. |
| Lifetime | Until the instance stops: a restart starts without state, a reload that keeps the instance keeps it. |
| Used for | Basic auth's cache, `<instance>.auth`: one digest of the last `Authorization` header let in. The ledger, `<instance>.scrape`: below. Each scrape's progress file, `<instance>.p<pid>_<start time>`, named by its process: a line `start <collector> <child pid>-<start time>` appended before each collector, `collected` once they are done, removed when the reply is written; one left by a dead process names the collector it was running, for the next scrape. The file a scrape's collectors' runs cross by, made with `mkstemp` and removed at once. |

### The ledger

`<instance>.scrape` is JSON, which every scrape of the handler reads when it starts and records itself in when it ends, re-reading it under the lock. `check` and the ubus object's `status` read the ledger of the instance that started last; `check --config`, which start and reload run, and the object's other methods do not.

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

An instance needs its start time besides its pid: in the jail's own pid namespace uhttpd has the same pid at every start. The start time is the 22nd field of `/proc/<pid>/stat`, counted after the `)` that ends the command name, which may hold spaces. The 32 KiB a file may hold is sized by the ledger, the largest: some 30 bytes for a collector that never failed and 300 for one that failed every way it can.

A ledger longer than a state file may be is written again without each breaker's `why` and each collector's failures by code: a state that cannot be written would lose the whole scrape's durations, breakers and counts.

## Files the service writes

| Path | Mode | Written by | Mounted |
| :--- | :--- | :--- | :--- |
| `/var/run/prometheus-exporter/` | 0700, root's | `jail.uc --make`, `auth.uc` | No |
| `/var/run/prometheus-exporter/uhttpd.conf` | 0640, root's and the service's group's | `auth.uc`, at each start: one line, `/metrics:<user>:<hash>`; removed without basic auth | Read-only, with basic auth |
| `/var/run/prometheus-exporter/tls.crt`, `tls.key` | 0640, root's and the service's group's | `jail.uc --make`, at each start, copies of `cert` and `key`, each only a regular file of at most 64 KiB under `/etc/ssl`, `/etc/acme` or `/etc/prometheus-exporter`, or `/etc/uhttpd.*`, wherever its links lead, read to at most that; neither when one is not; removed when the service stops | Read-only, with both there: the init script serves HTTPS only from them |
| `/var/run/prometheus-exporter/capabilities.json` | 0644 | `jail.uc --make`, at each start; removed when the service stops | No: procd hands it to ujail |
| `/var/run/prometheus-exporter.acl.json` | 0644 | `jail.uc --make`, at each start; removed when the service stops | No: ubusd reads it |
| `/var/run/prometheus-exporter/state/` | 0700, the service's user's | `jail.uc --make` | Read-write |
| `/var/run/prometheus-exporter/timesync/` | 0755 | `jail.uc --make` (timesync's owned path), or the hotplug script | Read-only |
| `/var/run/prometheus-exporter/timesync/ntpd` | 0644 | `/etc/hotplug.d/ntp/90-prometheus-exporter`, on each event of busybox ntpd, outside the jail | With its directory |
| `/var/prometheus/` (textfile's `directory`) | 0755 | `jail.uc --make` | Read-only |

The jail reads them as the service's user: textfile's `*.prom` files must be readable by it, as a file a script writes is (0644), or by its group; one only root reads is skipped, and logged.

uhttpd's auth file is written to a temporary name and renamed into place, so a running instance's jail, which bind-mounted the old file, reads that one until it restarts.

## Restarts

procd binds files into the jail. A file replaced by a new one, as `uci commit` replaces a config, stays the old one inside. So procd watches, for the uhttpd instance, the configs it mounts from `/etc/config`, every collector module, basic auth's file, the copies of the TLS files, which a reload makes again from the files `cert` and `key` name, and the capabilities file, and restarts the instance on `reload` when one changed.

## See also

- [Collector interface](collector-interface.md#meta): what a collector declares.
- [About the security model](../explanation/security.md)
