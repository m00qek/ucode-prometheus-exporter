# Changelog

What each release changes, for those who run the exporter and those who write collectors for it. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are [semantic](https://semver.org/): before 1.0.0 a minor version may break things, and says so, marked **BREAKING** here.

## [Unreleased]

Upgrading from 0.2.0 moves basic auth's hash to a config of its own, and refuses a few values 0.2.0 took: see [Upgrading the exporter](docs/how-to/upgrade.md#from-020-to-021).

### Added

- The ubus object's `password`, which says whether a hash of basic auth's password is saved, and `set_password`, which hashes a password, saves the hash and has the service reload; LuCI's ACL grants them in place of `hash_password`.

### Changed

- **BREAKING: basic auth's hash has a config of its own, `/etc/config/prometheus-exporter-auth`.** LuCI's read ACL granted the exporter's config, so a login allowed only to look at the settings could read the hash through rpcd's `uci` object, and guess the password offline. The hash moves to a config the package installs, mode 0600, which the app's ACL does not grant and the jail does not mount; LuCI asks `password` whether one is saved and saves a new one through `set_password`, which takes effect at once. The upgrade moves a hash from the main section, and logs it; `check` warns of one left there, which is ignored. A hash without `auth_user` is no basic auth now, not an invalid configuration, and the code `AUTH_NEEDS_USER` is gone. See [How to serve HTTPS with basic auth](docs/how-to/https-basic-auth.md).
- **BREAKING: textfile's `directory` must be under `/var`, `/tmp` or `/etc/prometheus-exporter`.** The service makes that directory as root and mounts it in its jail, and refused only a short list of directories every service shares: anyone who could write the exporter's configuration could have it make and mount most others. A directory elsewhere is now refused, with the new code `OWNED_DIRECTORY`, by `check`, a reload, the ubus object's `validate` and LuCI, and the jail neither makes nor mounts an owned path outside them. Move one under `/srv` or `/mnt` to `/etc/prometheus-exporter/...` before upgrading. A collector's option that names an owned path takes the new datatype `owned_directory`. See [The jail](docs/reference/jail.md#owned-paths).
- **The jail has the ubus socket only while an enabled collector needs ubus.** The jail runs as root, and ubusd lets root call any object: a router whose enabled collectors read files and netlink alone now runs the exporter without ubus, and so do `check`, the ubus object's `status` and `prometheus-exporter scrape`. The base package's `timesync` and `openwrt_interfaces` need it; disable both and the jail has none. A collector whose programs call ubus declares `ubus` in `meta.needs`. `jail.uc` prints the service's own mounts with the collectors', the ubus socket among them while one needs it, and the init script mounts what it prints. See [The jail](docs/reference/jail.md#what-a-collector-gets).
- uhttpd runs at most 3 requests at once over at most 10 connections (`-n 3 -N 10`), where it took its defaults of 3 and 100: one or two scrapers need no more, and a client that reaches the port can queue fewer scrapes behind it. The port is meant for the scrapers alone: [How to listen on the LAN](docs/how-to/listen-on-lan.md#keep-it-to-the-scrapers) has the firewall rules that keep it so, and [HTTP endpoint](docs/reference/http.md#keep-alive) says why keep-alive is 70 seconds.

### Fixed

- **A scrape spent nearly as long besides its collectors as in them.** Each collector's settings read the main section of the config two or three times over, and each value of a range option made its datatype anew: on the NanoPi R3S a scrape of 37 collectors took 0.79 to 0.89 s through uhttpd, 0.47 s of it collectors. A scrape now reads the main section once, a range is made once, and what was done for each family is done in one pass; on QEMU's 500-MIPS MIPS 24Kc a scrape of the `-full` group takes 1.16 s where 0.2.0 took 1.44 s, and 0.59 s besides its collectors where 0.2.0 took 0.87 s. Nothing waited on a timer: see [Performance on small routers](docs/explanation/performance.md#besides-the-collectors).
- **uhttpd kept six descriptors open for each collector.** Each collector was compiled as a program of its own, with its own copy of the collector API and the modules behind it, whose source files ucode keeps open: 268 descriptors for 37 collectors on the R3S, toward the limit of 1024. The collectors are compiled as one program, once each has loaded in a child process of its own: one descriptor each, and the API's once. Loading them takes 0.37 s on the 24Kc where it took 0.93 s, and uhttpd holds 3.5 MB where it held 5.2 MB. A collector that writes over what the API exports would now write over it for the others; none has a reason to.
- **The install guide left out the feed.** The base package depends on `ucode-docopt`, which OpenWrt's feeds do not have, so its `apk add` failed on a device without the exporter's feed. [How to install the exporter](docs/how-to/install.md) adds the feed and its key first, as the README and the tutorial do, and its `.apk` example names `ucode-docopt` and no stale version.
- **`hash-password` at a terminal dropped the spaces a password starts or ends with**, so the hash took another password than the one typed. It keeps them now, as it did from standard input: either way only the CR and LF that end the line go.
- **Basic auth failed open when its file was gone.** Should `/var/run/prometheus-exporter/uhttpd.conf` go while the service ran, and procd start uhttpd again as it was, the jail had no file to mount, and the handler served `/metrics` without a login. The handler now reads `auth_user` from the config, which the jail has, and denies every request while it is set and the file is not there, as it denies a file that is not right: `500`, logged at err. A restart writes the file again.
- **A `memory_limit` of 1 to 7 MB passed `check`, and uhttpd then crash-looped**: loading the handler takes 4 MB of data with the base package's collectors and 6 MB with all 45. `memory_limit` takes 0, a quarter of the RAM as before, or 8 MB and more, and refuses the rest with the new code `ZERO_OR_MIN`.
- **A renewed certificate was not picked up.** The jail kept the certificate and key the service started with, and a reload left the instance running, as their paths had not changed. A reload now restarts it when either file changed: see [How to serve HTTPS with basic auth](docs/how-to/https-basic-auth.md#renew-the-certificate).

## [0.2.0] - 2026-10-08

A slow or broken collector now costs only itself: a scrape answers within the scraper's timeout, runs each collector in a process of its own, and quarantines one that hangs, overruns or keeps failing. Upgrading from 0.1 takes a few steps: see [Upgrading the exporter](https://m00qek.github.io/ucode-prometheus-exporter/0.2/how-to/upgrade/#from-01-to-02).

### Added

- **A deadline per scrape.** A scrape answers within the timeout the scraper sends in `X-Prometheus-Scrape-Timeout-Seconds`, as Prometheus and vmagent do, less half a second; without it, within the new option `scrape_timeout`, 10 seconds. A collector the deadline has no time left for is left out, and a program still running at it is killed: both fail with `SCRAPE_DEADLINE`, logged once a scrape, at warning. See [About deadlines and circuit breakers](https://m00qek.github.io/ucode-prometheus-exporter/0.2/explanation/deadlines-and-breakers/).
- **Fastest first.** Each instance keeps a ledger of how long each collector takes, and a scrape runs the collectors fastest first, those it has not timed yet last, so a slow one no longer takes the ones after it with it. The reply keeps its order. The ledger is in RAM and a restart forgets it.
- **Circuit breakers.** A collector whose program is killed at its timeout, that takes longer than its budget, or that fails three scrapes in a row is quarantined: not run for 1 scrape, then 2, 4, up to 32, and tried again after each. The budget is the new option `collector_budget`, 5 seconds, or a collector's own `budget`. A quarantined collector fails with `COLLECTOR_QUARANTINED`, and `ucode_prometheus_exporter_collector_quarantined{collector}` is 1. `service prometheus-exporter check`, the ubus object's `status` and LuCI's status page say which collectors the service quarantined or left out, and why.
- **The `exporter` collector**, in the base package: the exporter itself, as Prometheus's client libraries describe a process (`process_cpu_seconds_total`, `process_resident_memory_bytes`, `process_open_fds`, ...), and what went wrong in its scrapes since it started: `ucode_prometheus_exporter_scrapes_total`, `_auth_failures_total`, `_collector_failures_total{collector,reason}`, `_program_timeouts_total`, `_quarantines_total`, `_deadline_skips_total`, and each collector's `_collector_samples` of the scrape.
- **Containment.** One collector can no longer impair the others or the service. See [Collector contract](https://m00qek.github.io/ucode-prometheus-exporter/0.2/reference/collector-contract/).
    - Each scrape runs its collectors in a child process, which is killed under one that is still running at the end of its budget: a loop that never ends or a system call that never returns fails that collector alone (`COLLECTOR_CANCELLED`), and the rest run in a new child. A child that dies under a collector, past the memory limit or in a native crash, fails it alone too (`COLLECTOR_KILLED`).
    - A collector writes at most `max_samples` samples a scrape, a new main option of 20,000, or its own: past it, it fails with `SAMPLE_LIMIT`, and none of its samples are served.
    - A metric family belongs to one collector, the exporter's own first: another that writes it fails with `FAMILY_CONFLICT`, and so does one that writes `node_scrape_collector_*` or `ucode_prometheus_exporter_*`.
    - A scrape keeps a progress file: the next scrape quarantines the collector a scrape process that died was running, and kills the child it left behind.
    - Every collector module is loaded in a child process first, for 5 seconds at most, when uhttpd starts: one that never returns is left out, logged at err, and the rest load.
    - The new option `memory_limit` limits the memory each of the service's processes may take: by default a quarter of the RAM, at most 64 MB. The service runs at nice 10, below hostapd, dnsmasq and netifd.
- `check`, the ubus object's `status` and `prometheus-exporter scrape` run the collectors in the service's jail, as Prometheus's scrapes do, where ujail can run; the `status` reply says whether it did in the new field `jailed`.
- The command's new subcommands: `collector check <path>`, which loads a collector not installed yet, runs it under the scrape's guards and says which rule of the contract it broke; `hash-password`, which reads a password without echo and prints the hash `auth_password` takes; and `--version`. See [The prometheus-exporter command](https://m00qek.github.io/ucode-prometheus-exporter/0.2/reference/command/).
- **The collector API**, `prometheus_exporter.api`: the one module a collector imports, which exports `Result`, `errors`, `services`, `proc` and `exposition`. What it exports is what a major version protects for collectors; the modules behind it may change in any release. `proc.auxv()` reads the auxiliary vector for any collector.
- What a collector may declare: `meta.max_samples`, its own sample limit (nat_traffic's is 65,536), and `meta.cost: 'heavy'`, which runs it after the others while the ledger has not timed it.
- A collector's tests, through `with_collector`, run it in the filesystem its jail gives it, and fail when it reads a path, opens a socket or runs a program its meta does not declare, which the service's jail would not have.
- **Typed doc comments.** Every export of the exporter's modules has a JSDoc block, with its types, which ucode-language-server shows on hover and checks calls against: a collector's `deps`, `out` and `options`, and what the API exports.
- How-to: [Pushing metrics from the router](https://m00qek.github.io/ucode-prometheus-exporter/0.2/how-to/push-metrics/), to a Pushgateway or VictoriaMetrics from cron. Reference: [Collector contract](https://m00qek.github.io/ucode-prometheus-exporter/0.2/reference/collector-contract/). The security explanation states the threat model: collectors are buggy, not hostile.
### Changed

- **BREAKING: the command line takes subcommands**, parsed by docopt from its usage text: `prometheus-exporter [COLLECTOR...]` is `prometheus-exporter scrape [COLLECTOR...]`, and `prometheus-exporter -l` is `prometheus-exporter collector list`. The base package depends on `ucode-docopt`.
- **BREAKING for collectors: a collector imports `prometheus_exporter.api` and nothing else**, and calls neither `require`, `loadfile` nor `loadstring`; the loader leaves out one that does, logged at err with what to use instead. Its capabilities in `deps` do what it imported `fs`, `ubus` or `uci` for. Every collector of the exporter's packages does already; one written for 0.1 takes `Result`, `errors` and `proc` from the API, and `proc.first_line()` for `first_line()`.
- **BREAKING for collectors: a collector module is in strict mode**, `'use strict'` its first statement; the loader leaves out one that is not.
- **BREAKING for collectors: each option of `meta.options` has a `title`**, a label of 1 to 40 characters in sentence case, as `title: 'Excluded devices'`; the loader leaves out a collector with an option that has none, logged at err. LuCI's Edit dialog labels the option by it, untranslated, where it showed the option's name; the core's options of a collector are labelled by LuCI, translated (Program timeout, Budget, Sample limit). The ubus object's `collectors` gives each option's `title`. Every collector of the exporter's packages has them.
- **BREAKING: the ubus object's `validate` answers each value it refuses with an object, not a sentence**: a code of a closed set, its arguments and the English as `message`, as `{ "code": "RANGE", "min": 1, "max": 65535, "value": 0, "message": "expected an integer from 1 to 65535, got 0" }`. The codes are listed in [UCI configuration](https://m00qek.github.io/ucode-prometheus-exporter/0.2/reference/uci-config/#problems). LuCI says each in the user's language, naming the field by its title, and shows `message` for a code it does not know. `check`, the log and the command line print the English they printed.
- A collector's package no longer depends on what it watches: those of mwan3, chrony, modemmanager, ubnt-manager and wireguard installed mwan3, chronyd, ModemManager, ubnt-manager and rpcd-mod-wireguard. Where it is not there, the collector has nothing to observe. An upgrade removes nothing that was installed.
- The exporter's modules are split into smaller ones, behind facades (`config/`, `deps/`, `exposition/`, `loader/`, `rpc/`), with no change of behaviour; the package installs their directories.
- The state of an instance is written under a lock, so concurrent requests, a scraper, LuCI and curl, each update it whole.
- LuCI's status page says what needs attention in a banner above the tables: the service enabled and not running, switched off, collectors failed or quarantined. The rows are grouped worst first, and the page's own scrape, the Test run, is a column apart from the Service's scrapes.
- LuCI's settings split the Exporter tab into General, HTTPS & login and Limits, and the Limits tab takes `scrape_timeout`, `collector_budget` and `max_samples`.
- LuCI: a refused Save opens LuCI's own error dialog, wherever the page is scrolled, naming each field by its tab with a link to it; the Edit dialog's text is legible in every theme, and the focus returns to Edit when it closes; a read-only login can open Edit; the collectors are listed by title.

### Removed

- **BREAKING: the `wifi_stations` collector and its package.** It wrote the families `wifi`'s option `stations` writes, so each station was exported twice; `wifi`'s stations, on by default, are what it was. Remove `ucode-prometheus-exporter-wifi_stations` before upgrading.

### Fixed

- textfile no longer hangs on a FIFO named `*.prom`: it reads regular files alone, and counts any other in `node_textfile_scrape_error`.
- textfile found no files in the service when its `directory` option ended in a `/`: the jail now mounts it.
- Two requests writing the instance's state at once could leave a half-written file in place.
- LuCI showed a raw `RPCError` and its stack trace while rpcd restarts; it now says in words that the exporter's ubus object is not available, and the page is read-only until it is.

## [0.1.0] - 2026-10-01

The first release: a rewrite of the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua` for OpenWrt 25.12, served by uhttpd at `/metrics` on port 9100. See the [documentation](https://m00qek.github.io/ucode-prometheus-exporter/0.1/).

### Added

- 45 collectors, the ucode exporter's and the Lua exporter's ported alongside, under node_exporter's metric names: 15 in the base package, each other a package of its own, with the `-network`, `-wireless`, `-hardware` and `-full` groups. The [renamed metrics](https://m00qek.github.io/ucode-prometheus-exporter/0.1/metrics/) say what the feed's names became.
- A jail for the service, built from what each collector declares it reads and runs.
- HTTPS and basic auth, with the password stored as a crypt hash of at most 2000 rounds; a header let in once is let in again without computing the hash. gzip when the scraper asks, `http_keepalive` (0 closes each connection), and leaving out counters that are 0.
- The import of a feed exporter's settings on first install.
- WireGuard peers named by their description only with the `peer_names` option, read through rpcd, so the jail never holds the private keys.
- A ubus object, `prometheus-exporter`, which the LuCI app, `luci-app-prometheus-exporter`, uses for its settings and status pages.
- The documentation site, in the Diátaxis structure, published per minor version.

[0.2.0]: https://github.com/m00qek/ucode-prometheus-exporter/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/m00qek/ucode-prometheus-exporter/releases/tag/v0.1.0
