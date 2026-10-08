# Changelog

What each release changes, for those who run the exporter and those who write collectors for it. The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions are [semantic](https://semver.org/): before 1.0.0 a minor version may break things, and says so, marked **BREAKING** here.

## [Unreleased]

### Added

- **`u32()` and `u16()` in the collector API**: a ubus integer a daemon sent unsigned (`blobmsg_add_u32()`, `blobmsg_add_u16()`), which ucode's ubus gives signed, as the value the daemon meant. See [Collector interface](docs/reference/collector-interface.md#the-collector-api).

### Changed

- **BREAKING: nat_traffic labels an IPv6 address compressed**, as RFC 5952 writes it and every other collector labels it: `src="2001:db8:0:1::e157"`, where it had the kernel's `2001:0db8:0000:0001:0000:0000:0000:e157`, which joined nothing. A table of 20,000 connections takes as long as before.
- **BREAKING: netstat exports node_exporter's default fields only**, those its `--collector.netstat.fields` keeps: the errors, IP forwarding and octets, ICMP messages, TCP's connections, segments, retransmissions, listen queue and SYN cookies, and UDP's datagrams and buffer errors, 42 series on a router where it wrote about 400. The new option `fields`, a regular expression of `<Section>_<Field>` as vmstat's `fields` is, takes others: `option fields '.*'` exports every one, as before.
- **BREAKING: hostapd_stations labels each station's series by `vif` and `station` alone.** `ssid`, `bssid`, `encryption`, `frequency` and `channel` moved off every `hostapd_station_*` series to the new `hostapd_station_info{vif,station,ssid,bssid,encryption,frequency,channel}`, one per station: a channel change (DFS, ACS) started a new series of every station's counters. A query that selected by them joins the info metric: `hostapd_station_signal_dbm * on (vif, station) group_left (ssid) hostapd_station_info`.

### Fixed

- loadavg left out an average of `/proc/loadavg` that was not a number, and succeeded without it; it fails with `SOURCE_INVALID`, writing none.
- `node_wifi_network_quality_ratio` went past 1 for stations stronger than -40 dBm, and below 0 under -110 dBm; it is kept from 0 to 1.
- wifi's option `stations` off also left out `node_wifi_stations`, how many stations each interface has, which is no per-station series; it is written either way.
- **selinux reported SELinux off in the service wherever it was on.** The jail's sysfs is a fresh one, without selinuxfs mounted under it, so `/sys/fs/selinux/enforce` was never there. Without it, selinux asks `/proc/filesystems`, which lists selinuxfs only where SELinux is enabled: `node_selinux_enabled` is 1 there, without `node_selinux_current_mode`, which only enforce tells; 0 only where the kernel has no SELinux.
- hostapd_stations wrote 0 for a byte or packet count hostapd did not give a station, which Prometheus takes for a counter reset; it leaves the sample out.
- **A failed netlink request said nothing of why**: on a real access point, `collector 'netdev': RTNL_FAILED`, `collector 'wifi': NL80211_FAILED (phy0-ap0: null)` and `collector 'netclass': SOURCE_INVALID (RTM_GETLINK: false)`. ucode's rtnl and nl80211 clear their error as `error()` reads it, and the capability read it twice; a request the kernel refused, which they answer with `false`, was taken for a reply. The capability reads the error once and fails a `false` reply too, so the log says why, as `RTNL_FAILED (Operation not permitted)`.
- **Counters from ubus went negative past 2^31.** ucode's ubus gives a 32-bit integer signed, whatever the daemon meant: dnsmasq's metrics could read `-2147483000`, hostapd_stations' packet counts too, and an odhcpd lease that never expires (`valid` of (uint32_t)-1, given as -1) got an expiry a second before the scrape, as if it had expired. dhcp_leases' `iaid` past 2^31 was labelled negative. Each is read unsigned, with the API's new `u32()`; wireguard uses it and `u16()` where it had its own.
- **filesystem exported nothing in the service, and said it succeeded.** It joined luci's `getMountPoints` with `/proc/self/mounts`, which in the service's jail is the jail's own mount table: on a router no mount matched, and `ucode_prometheus_exporter_collector_samples{collector="filesystem"}` was 0. It reads the host's `/proc/mounts` through rpcd (`ubus call file read`), rpcd-mod-file, which luci-base, the package's dependency, depends on. The read-only flag is the host's mount's, no longer the jail's.
- **A scrape spent nearly as long besides its collectors as in them.** Each collector's settings read the main section of the config two or three times over, and each value of a range option made its datatype anew: on the NanoPi R3S a scrape of 37 collectors took 0.79 to 0.89 s through uhttpd, 0.47 s of it collectors. A scrape now reads the main section once, a range is made once, and what was done for each family is done in one pass; on QEMU's 500-MIPS MIPS 24Kc a scrape of the `-full` group takes 1.16 s where 0.2.0 took 1.44 s, and 0.59 s besides its collectors where 0.2.0 took 0.87 s. Nothing waited on a timer: see [Performance on small routers](docs/explanation/performance.md#besides-the-collectors).
- **uhttpd kept six descriptors open for each collector.** Each collector was compiled as a program of its own, with its own copy of the collector API and the modules behind it, whose source files ucode keeps open: 268 descriptors for 37 collectors on the R3S, toward the limit of 1024. The collectors are compiled as one program, once each has loaded in a child process of its own: one descriptor each, and the API's once. Loading them takes 0.37 s on the 24Kc where it took 0.93 s, and uhttpd holds 3.5 MB where it held 5.2 MB. A collector that writes over what the API exports would now write over it for the others; none has a reason to.

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
