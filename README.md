# ucode-prometheus-exporter

Metrics of OpenWrt for Prometheus, written in ucode and served by uhttpd at `/metrics` on port 9100. A rewrite of the packages feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua`, with the Lua exporter's collectors ported alongside the ucode one's. It replaces them, under names of its own: the package `ucode-prometheus-exporter`, the service, command and config `prometheus-exporter`. It conflicts with both, and takes over their settings (see [Coming from the feed's exporters](#coming-from-the-feeds-exporters)).

The metric names are not those packages'. They are the Prometheus [node_exporter](https://github.com/prometheus/node_exporter)'s where it has the metric, so its dashboards work, and elsewhere follow the [Prometheus naming conventions](https://prometheus.io/docs/practices/naming/) (base units, `_total` on counters only, `_info` for labels); a service keeps its own prefix, and the names of its standalone exporter where they follow the conventions. [docs/metrics.md](docs/metrics.md) lists every name that changed, and why.

It targets OpenWrt 25.12 and uses no ucode API newer than that release's.

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Using it

```sh
apk add ucode-prometheus-exporter ucode-prometheus-exporter-openwrt
wget -qO- http://127.0.0.1:9100/metrics                      # every installed collector
wget -qO- 'http://127.0.0.1:9100/metrics?collect[]=loadavg' # some of them (also exclude[]=)
prometheus-exporter -l                                      # list the collectors
prometheus-exporter loadavg                                 # a scrape, on the command line
```

The base package has the collectors every device can use (cpu, meminfo, netdev, netclass, loadavg, conntrack and more); each other collector is its own `ucode-prometheus-exporter-<name>` package. Groups install several at once:

| | |
|---|---|
| `-network` | ethtool, nat_traffic, netstat, nft-counters, snmp6 |
| `-wireless` | wifi, hostapd_stations, hostapd_ubus_stations |
| `-hardware` | hwmon, thermal, filesystem |
| `-full` | the three above, and dhcp_leases, dnsmasq, openwrt, textfile, uci_dhcp_host, wireguard |

The collectors of particular hardware or services (ltq-dsl, realtek-poe, bmx7, mwan3, modemmanager, ubnt-manager, dawn, unbound) and wifi_stations, which repeats wifi's station metrics, are in no group.

Every collector, with its title and package (`ucode-prometheus-exporter-…`):

| | | |
|---|---|---|
| `bmx7` | bmx7 mesh | `-bmx7` |
| `conntrack` | Connection tracking | base |
| `cpu` | CPU | base |
| `dawn` | DAWN band steering | `-dawn` |
| `dhcp_leases` | DHCP leases | `-dhcp_leases`; in `-full` |
| `dnsmasq` | dnsmasq DNS and DHCP | `-dnsmasq`; in `-full` |
| `entropy` | Kernel entropy | base |
| `ethtool` | Network driver statistics | `-ethtool`; in `-network`, `-full` |
| `filefd` | File descriptors | base |
| `filesystem` | Filesystems | `-filesystem`; in `-hardware`, `-full` |
| `hostapd_stations` | hostapd stations | `-hostapd_stations`; in `-wireless`, `-full` |
| `hostapd_ubus_stations` | hostapd station capabilities | `-hostapd_ubus_stations`; in `-wireless`, `-full` |
| `hwmon` | Hardware sensors | `-hwmon`; in `-hardware`, `-full` |
| `loadavg` | Load average | base |
| `ltq-dsl` | Lantiq DSL line | `-ltq-dsl` |
| `meminfo` | Memory | base |
| `modemmanager` | Cellular modems | `-modemmanager` |
| `mwan3` | mwan3 multi-WAN | `-mwan3` |
| `nat_traffic` | Traffic per address pair | `-nat_traffic`; in `-network`, `-full` |
| `netclass` | Network device properties | base |
| `netdev` | Network device statistics | base |
| `netstat` | Protocol statistics | `-netstat`; in `-network`, `-full` |
| `nft-counters` | nftables counters | `-nft-counters`; in `-network`, `-full` |
| `openwrt_interfaces` | OpenWrt interfaces | base |
| `openwrt` | OpenWrt release and board | `-openwrt`; in `-full` |
| `realtek-poe` | Realtek PoE | `-realtek-poe` |
| `selinux` | SELinux | base |
| `snmp6` | IPv6 statistics per device | `-snmp6`; in `-network`, `-full` |
| `softnet` | Network softirq statistics | base |
| `textfile` | Text files | `-textfile`; in `-full` |
| `thermal` | Thermal zones | `-thermal`; in `-hardware`, `-full` |
| `time` | System time | base |
| `ubnt-manager` | Ubiquiti airOS radios | `-ubnt-manager` |
| `uci_dhcp_host` | Static DHCP hosts | `-uci_dhcp_host`; in `-full` |
| `uname` | Kernel and host names | base |
| `unbound` | Unbound DNS resolver | `-unbound` |
| `vmstat` | Virtual memory statistics | base |
| `wifi_stations` | Wi-Fi stations | `-wifi_stations` |
| `wifi` | Wi-Fi | `-wifi`; in `-wireless`, `-full` |
| `wireguard` | WireGuard | `-wireguard`; in `-full` |

Neither upstream exporter had these: softnet and vmstat (node_exporter's), conntrack's statistics and openwrt_interfaces (netifd's logical interfaces: up, uptime, devices, address counts) in the base package, and dhcp_leases (dnsmasq's and odhcpd's active leases).

## Coming from the feed's exporters

The package conflicts with the feed's `prometheus-node-exporter-ucode` and `prometheus-node-exporter-lua` (both serve `/metrics` from uhttpd, the Lua one on this port): apk installs neither beside it, nor it beside either, and says why:

```
ERROR: unable to select packages:
  prometheus-node-exporter-ucode-2024.02.07-r2:
    breaks: ucode-prometheus-exporter-2026.09.30-r1[!prometheus-node-exporter-ucode>=0]
```

So the old one goes first:

```sh
apk del prometheus-node-exporter-ucode && apk add ucode-prometheus-exporter
```

apk keeps the old exporter's config when someone changed it. When the package is installed, a uci-defaults script takes what it sets into `/etc/config/prometheus-exporter`: `listen_interface`, `listen_port`, `http_keepalive`, `cert`, `key`, `omit_zero_values`, and the ucode exporter's `config collector` sections (wifi's `stations`). It does so once, only while `/etc/config/prometheus-exporter` is as the package ships it, and from the ucode exporter's config when both are there:

- A port left at the old exporter's default (the ucode one's 9101) becomes 9100; one someone chose is kept.
- A value this exporter would refuse is left at the default.
- The old config file stays as it was.
- The log (`logread -e prometheus-exporter`) says what was taken and what was not.

The metric names are not the old exporters' ([docs/metrics.md](docs/metrics.md)), and Prometheus may need the new port.

## Configuration

`/etc/config/prometheus-exporter` is optional: every option has a default.

```
config prometheus-exporter 'main'
	option enabled '1'                 # 0: the service does not run
	option listen_interface 'loopback' # a logical interface, or * for every address
	option listen_port '9100'
	option http_keepalive '70'         # seconds; 0 for none
	option omit_zero_values '0'        # 1: leave out counters that are 0
	option exec_timeout '5'            # seconds a collector's programs get per scrape, 1 to 30
	option compress '1'                # 0: never gzip a scrape
	#option cert '/etc/uhttpd.crt'     # both, for HTTPS
	#option key '/etc/uhttpd.key'
	#option auth_user 'prometheus'     # basic auth, with cert and key only
	#option auth_password '$6$rounds=1000$...' # a crypt hash, never the password

config collector 'textfile'          # named after the module: ltq_dsl for ltq-dsl
	option enabled '1'                 # 0: not served; naming it in a query is a 400
	option directory '/var/prometheus'

config collector 'ubnt_manager'
	option timeout '10'                # its programs' seconds, over exec_timeout
```

A collector without a section is enabled, with its defaults. Every collector has `enabled`, and every one that runs programs (ethtool, nft-counters, modemmanager, ubnt-manager) has `timeout` too: the core's options, which no collector declares itself (see [the service](#the-service)). These take options of their own (`check` prints each with its help):

| | | |
|---|---|---|
| `dhcp_leases` | `leases` | `0`; 1 adds a series per lease (address, MAC, hostname, expiry) |
| `textfile` | `directory` | `/var/prometheus`; an absolute path, where the `*.prom` files are; the service makes it when it starts and it is not there |
| `unbound` | `socket` | `/var/lib/unbound/unbound.ctl`; an absolute path, unbound's control socket (`control-interface`), in a directory the jail can mount (see the jail) |
| `vmstat` | `fields` | `^(oom_kill\|pgpg\|pswp\|pg.*fault).*`; a regex of the /proc/vmstat fields |
| `wifi` | `stations` | `1`; 0 leaves out the per-station metrics |

A config change applies on `reload_config` (LuCI does it), or `service prometheus-exporter reload`.

uci rewrites the whole file when it commits a change (`uci commit`, and so LuCI's Save & Apply): the comments of the config as the package ships it do not survive a save, and options come out in uci's order.

### Gzip

A scrape is sent gzip-compressed when the scraper asks for it (`Accept-Encoding: gzip`, as Prometheus and vmagent send it), as node_exporter does: `Content-Encoding: gzip`, and `Vary: Accept-Encoding` on every reply while `compress` is on. A scraper that does not ask, or refuses gzip (`gzip;q=0`), gets plain text; `option compress '0'` never gzips. The handler compresses with ucode-mod-zlib at its fastest level.

A whole scrape of the lab (every collector, about 1250 series, on x86_64) is 143,500 bytes plain and 21,640 gzipped, 6.6 times smaller; deflating it takes about 1 ms (3 ms at zlib's default level, for 19,160 bytes). Over loopback the scrape takes as long either way (118 ms plain, 123 ms gzipped); the gain is on the wire, 85% fewer bytes per scrape.

### Basic auth

`auth_user` and `auth_password` make a scrape log in (HTTP basic auth). Basic auth sends the password in the clear, so it is taken over HTTPS only: `cert` and `key` must be set, and their files there. Otherwise the configuration is invalid, and refused wherever it is checked: start does not start, reload keeps the running exporter (the log says why), `check` fails saying why, and the ubus object's `validate` and LuCI refuse to save it. So is half of it: a user without a hash, or a hash without a user.

`auth_password` holds the password's crypt hash, never the password: `$1$` (MD5-crypt, what `uhttpd -m <password>` prints), `$5$` or `$6$` (SHA-256-crypt and SHA-512-crypt, with their `rounds=`, at most 2000). Anything else is refused: DES's 13 characters (a plain password could look like one), bcrypt, `$p$` lookups of system accounts, and a `$5$` or `$6$` hash of more than 2000 rounds, including one that names none, which has 5000 (`openssl passwd -6` makes those; `mkpasswd -m sha-512 -R 1000` does not). The ubus object makes one, freshly salted, without the password on a command line:

```sh
ubus call prometheus-exporter hash_password '{"password":"…"}'   # { "hash": "$6$rounds=1000$…" }
uci set prometheus-exporter.main.auth_user='prometheus'
uci set prometheus-exporter.main.auth_password='$6$rounds=1000$…'
uci set prometheus-exporter.main.cert='/etc/uhttpd.crt' prometheus-exporter.main.key='/etc/uhttpd.key'
uci commit prometheus-exporter && reload_config
```

The init script writes uhttpd's config file, `/var/run/prometheus-exporter/uhttpd.conf` (mode 0600, in a directory of mode 0700): one line, `/metrics:<user>:<hash>`. uhttpd reads it (`-c`), with the realm `prometheus-exporter` (`-r`), and the jail mounts it read-only. OpenWrt 25.12's uhttpd checks such a realm for files and CGI, not for a handler's prefix (its fix, uhttpd 3aa7e1c of August 2026, is newer than every 25.12 release so far): so the handler checks it itself, against the same file, before any scrape. A request without the user and password is a 401 (`WWW-Authenticate: Basic realm="prometheus-exporter"`); the hash itself is no password. Neither the password nor the hash is logged, and no reply of the ubus object holds the hash (its `status` says only whether basic auth is on); `check` names the user.

The handler computes the hash in ucode to check the password, so its rounds are what a check costs (`make bench`'s `auth:` cases, the median of a check in a process of its own):

| | `$1$` | `$6$`, 1000 rounds (`hash_password`'s) | `$5$`, 2000 | `$6$`, 2000 | by the cache |
|---|---|---|---|---|---|
| devenv (Ryzen 7 7840U) | 2.5 ms | 4.1 ms | 6.5 ms | 7.8 ms | 0.09 ms |
| NanoPi R3S (4×A55) | 14 ms | 19 ms | 33 ms | 37 ms | 0.5 ms |
| QEMU malta, 24Kc at 500 MIPS | 63 ms | 135 ms | 206 ms | 259 ms | 2.4 ms |

A round of SHA-512-crypt takes a 500-MIPS 24Kc (an MT7621-class router) 125 µs: the 9,999,999 rounds a hash may name would take 20 minutes, the default 5000 0.63 s. So a hash takes at most 2000 rounds (`auth.ROUNDS_MAX`), a quarter of a second there, and more is refused wherever the config is checked, as any invalid value is; the message says how many rounds it takes, never the hash.

Even 1000 rounds are 135 ms of each scrape on such a router, and uhttpd forks a process per request, which keeps nothing in memory. So the handler keeps a cache in the instance's state: after a request is let in, the SHA-256 of its exact `Authorization` header, the user and the hash (`auth.digest`), in `/var/run/prometheus-exporter/state/<instance>.auth`, one entry, mode 0600. A later request whose header gives the same digest, compared in constant time, is let in without computing the hash; any other header pays the full check, and a wrong one stays out as before, leaving the entry as it was. The entry is bound to the user and hash, so a changed password (or user) lets nothing in by it; and it is the instance's own, gone when the service restarts.

The entry reveals no more than what is already on the device: the hash sits beside it, as closed (root's alone, a directory of mode 0700 on tmpfs, never on flash nor in a backup, as `/etc/config` is), and finding a header that gives the digest is guessing the password, as with the hash. A guess costs less against the digest (one SHA-256) than against the hash (1000 rounds and more): which matters only to whoever can read the file, that is root on the router, who can read the password itself from the next scrape (uhttpd ends the TLS); a long random password, as a scraper's should be, is out of reach either way.

The exporter's state is a directory of its own, `/var/run/prometheus-exporter/state` (mode 0700, made by the init script's `jail.uc --make`), the one path the jail mounts read-write. It belongs to a uhttpd instance: the handler names the instance when uhttpd loads it, before any request (the pid and start time of that process, as the jail's pid namespace gives it the same pid each time), each file is `<instance>.<name>`, and the handler removes every other instance's files when it loads. A restart (`service prometheus-exporter restart`, a changed config or collector) starts without state; a reload that keeps the instance keeps it.

In Prometheus (vmagent takes the same `scrape_configs`):

```yaml
scrape_configs:
  - job_name: openwrt
    scheme: https
    basic_auth:
      username: prometheus
      password_file: /etc/prometheus/openwrt.password
    tls_config:
      ca_file: /etc/prometheus/openwrt.crt   # the router's certificate, self-signed
      server_name: router.lan                # a name the certificate holds
      # insecure_skip_verify: true           # or: no check of the certificate at all
    static_configs:
      - targets: [ 'router.lan:9100' ]
```

## The service

| | |
|---|---|
| `service prometheus-exporter check` | checks the config (with HTTPS, basic auth's user, and whether a scrape is gzipped when asked), lists each collector (title, section, options with their help, needs, what the jail gives it) and runs a scrape, saying what fails and why |
| `… status` | running, and where it listens, whether a scrape logs in (basic auth) and is gzipped when asked, and how many collectors it serves; or disabled |
| `… reload` | starts again with the new config; an invalid one keeps the running exporter, and the log says why |

Start and reload refuse an invalid config. Installing or removing a collector package reloads the service.

It logs to syslog as `prometheus-exporter` (`logread -e prometheus-exporter`), each line at its priority: `info` for what it does (how many collectors it serves when it starts, a directory it made, the settings it took over), `warning` for what it does without (a collector that fails, which the scrape answers without; a path the jail cannot mount), `err` for what stops it (an invalid config, a collector that does not load).

The programs a collector runs (nft, ethtool, mmcli, ubnt-manager) get 5 seconds in all in each scrape, by default. One still running then is killed, with every process it started (ubnt-manager's ssh to a radio that does not answer), and its collector fails with COMMAND_TIMEOUT; the scrape answers with the rest. A collector stuck for its 5 seconds still leaves the scrape within Prometheus's default `scrape_timeout` of 10 seconds.

The seconds, 1 to 30, are the collector section's `timeout` when it sets one, else the collector's own default (`meta.timeout`, which none of the shipped collectors has), else the main section's `exec_timeout` (5 by default). A value outside 1 to 30 fails `check`, and start and reload: `exec_timeout` as the main section's, a collector's `timeout` as that collector's, which fails with CONFIG_INVALID in a scrape. A collector that runs no programs ignores a `timeout`. `check` prints each one's seconds and where they come from:

```
  ubnt-manager (Ubiquiti airOS radios): section 'ubnt_manager', enabled
      timeout  10s # its section's option timeout
```

uhttpd runs in procd's jail, and a collector gets what it declares: procfs, sysfs, ubus and the log for all, then the configs it reads (`/etc/config/dhcp` for uci_dhcp_host), the files and directories it reads (textfile's directory, dhcp_leases' lease files, bmx7's status), and the programs it runs with their libraries (`/bin/sh` and `nft` for nft-counters). Nothing else of `/etc/config` is there. What the jail cannot give is a warning in `check`:

- textfile's directory (`/var/prometheus` by default) is the exporter's own: the service makes it, with its parents, when it starts and it is not there, so the jail always mounts it. No other service's directory is ever made.
- Any other path that is not there when the service starts is left out, and a `watch` instance beside uhttpd looks for it every 5 seconds: once it is there, procd reloads the service, which mounts it. So unbound's socket directory, which unbound makes when it starts (after the exporter, at boot), is mounted a few seconds later.
- ujail cannot mount a socket, so a collector gets the socket's directory. That is never one every service shares, such as `/run`. OpenWrt's unbound package makes no Unix control socket; the `socket` option's default is where to have it, in `/var/lib/unbound`, the directory the package makes for unbound alone (and its chroot). In `/etc/unbound/unbound_ext.conf`:

  ```
  remote-control:
  	control-enable: yes
  	control-interface: /var/lib/unbound/unbound.ctl
  ```

  The jail then mounts `/var/lib/unbound` read-only, and with it unbound's generated config and `root.key`, and its TLS keys if `unbound_control` makes them.

## The ubus object

The service has a ubus object, `prometheus-exporter`, which the base package installs: the exporter is a handler uhttpd runs per request and publishes nothing itself, so rpcd serves the object, from a ucode plugin (`/usr/share/rpcd/ucode/prometheus-exporter.uc`, over `src/prometheus_exporter/rpc.uc`). It is what the LuCI app calls, and needs no LuCI: a script on the router, or anything that reaches ubus, can ask it.

```sh
ubus call prometheus-exporter collectors                              # the installed collectors, their options and jail
ubus call prometheus-exporter validate '{"main":{"listen_port":"0"}}' # what the exporter would refuse, and why
ubus call prometheus-exporter status                                  # runs a scrape: how each collector does
ubus call prometheus-exporter interfaces                              # the logical interfaces to listen on
ubus call prometheus-exporter hash_password '{"password":"…"}'        # auth_password's hash of a password
```

It reads with the exporter's own modules, so it sees what the exporter sees, and writes nothing: settings change through uci.

| | |
|---|---|
| `collectors {}` | `{ collectors: [ { name, id, title, help, enabled, package, base, options: [ { name, core, type, default, help, datatype, value, set, error } ], needs, configs, commands, jail: { paths, owned, commands, mounts, problems, missing }, error } ], skipped }` |
| `validate { main?, collectors? }` | `{ ok, errors: { main: { <option>: message }, collectors: { <module>: { <option>: message } } } }` for values as uci holds them |
| `status {}` | `{ service: { enabled, boot, running, error, auth, compress }, listen: [ url ], collectors: [ { name, id, title, enabled, success, duration, error, mounts } ] }` |
| `interfaces {}` | `{ interfaces: [ { name, proto } ] }` |
| `hash_password { password }` | `{ hash }`: a SHA-512-crypt hash of 1000 rounds, freshly salted, for `auth_password` |

- `collectors` and `validate` read the committed configuration, as the exporter does. `validate` checks each value alone, as the exporter would read it: an empty one is unset, and options nobody declared and collectors that are not installed are ignored. The main section's options that go together, basic auth's user and hash and the `cert` and `key` they need, are checked as if the values given were the whole section. No message holds `auth_password`'s value.
- `hash_password` takes a password of 1 to 256 bytes without control characters; rpcd runs it, unjailed, and logs neither the password nor the hash.
- A collector's `options` are its own (`core: false`), then, when it runs programs, the core's `timeout` (`core: true`, `datatype` `range(1,30)`): its `default` is the seconds it gets while unset, and `default_from` says whose they are, `meta.timeout` or `exec_timeout`. `validate` takes `timeout` for those collectors, and `exec_timeout` in `main`.
- `status` scrapes the enabled collectors once, outside the jail, as `check` does, in a process of its own (`/usr/libexec/prometheus-exporter/rpc-status.uc`), and replies when it is done: rpcd answers other calls meanwhile, the collectors' calls to objects rpcd itself serves (`wireguard`, `luci`) among them.
- `interfaces` is what netifd says (`network.interface dump`), names and protocols only. It never reads `/etc/config/network`, which holds secrets, so a caller allowed this object alone gets every interface.
- Malformed arguments, and a call that fails, are answered `{ error, message }`.

Over HTTP (uhttpd-mod-ubus) a login needs the methods in its ACL; the LuCI app's grants them.

## Developing

Everything runs in OpenWrt's own images (Docker), on the release in `OPENWRT_VERSION` (25.12.5 by default; CI also runs 25.12.0).

| | |
|---|---|
| `make test` | unit and integration tests (utest); `unit`, `integration`, `watch`; `FILTER=`, `VERBOSE=1`, `MODULES=` |
| `make lint` | loads every module on 25.12's ucode, so a function it lacks fails here |
| `make package` | the apks, built with the OpenWrt SDK, into `bin/` |
| `make package-check` | installs them offline, scrapes a real uhttpd on loopback and calls the ubus object in a real rpcd, with the base package alone and then with the LuCI app |
| `make e2e` | boots OpenWrt (procd, ubusd, netifd) in a privileged container and checks the service, in its jail, as packages come and go and its config changes, and its ubus object, with no LuCI installed |
| `make lab` | the built packages, every collector and the LuCI app on OpenWrt under procd, in a privileged container left running: LuCI on <http://127.0.0.1:8080/> (root, no password), `/metrics` on <http://127.0.0.1:9100/metrics>; `LAB_ADDRESS=`, `LAB_LUCI_PORT=`, `LAB_METRICS_PORT=`, `LAB_NAME=` |
| `make lab-down` | removes it |
| `make fixtures HOST= NAME=` | reads `test/fixtures/SOURCES` from a device over ssh into `test/fixtures/NAME/` |

The lab is a device to try things on: `docker exec -it ucode-prometheus-exporter-lab ash` for a shell, and `make lab` again for new packages, which starts it afresh. It has its own network namespace on docker's default bridge, where docker gave eth0 its address and route and forwards the published ports there. So OpenWrt's network config is written before it boots (`devenv/services/lab/boot.sh`): `lan` is eth0 itself, with the address and gateway docker gave it, and no bridge (the generated config's lan bridge over eth0 would take the address away, and netifd takes down a device it is not told about). The firewall and mwan3 do not start: fw4 would reject what docker forwards, and mwan3 would rewrite the routing. The exporter listens on every address (`listen_interface '*'`), unbound on port 5353 with its control socket where the unbound collector looks, textfile has a file to read, and ubnt-manager's sample radio is gone (with a route out, ssh to it would cost each scrape ubnt-manager's 5 seconds, and fail it).

Layout: `src/prometheus_exporter/` is the ucode library (installed to `/usr/share/ucode/prometheus_exporter/`), `files/` the handler, command, init script, config and rpcd plugin, `openwrt/` the package Makefile, `test/unit/` mirrors `src/`, `test/bench/` is the benchmark.

### Benchmarks

| | |
|---|---|
| `make bench` | each collector and whole scrapes on generated worlds, in the pkgcheck image: a table, and `bin/bench/<label>.json`; checked against `test/bench/budgets.uc`, as in CI; `FILTER=` (a regex of `world/case`), `BENCH_ARGS=` (`-r N` runs at least, `-t S` seconds at least), `BENCH_REV=` (another revision's `src/`, for a before and after) |
| `make bench BENCH_CPUS= BENCH_CPUSET= BENCH_MEMORY=` | the same in a container limited as a slower router: a share of a CPU (a CFS quota, 0.05 at least), the CPUs it may use, its memory |
| `make bench-device HOST=` | the same on a device over ssh, from its `/tmp`, with its own ucode, beside whatever it runs: nothing is installed, and everything copied is removed afterwards; `BENCH_DEVICE_LABEL=`, `BENCH_REV=` |
| `make bench-qemu` | the same on OpenWrt's malta target in qemu-system-mipsel: a MIPS 24Kc (mipsel_24kc, the packages of MT7621-class routers) with the built packages installed from the release's feed; `QEMU_SHIFT=` (1), `QEMU_MEMORY=` (128) |
| `make bench-worlds` | the worlds, in `bin/bench/worlds/` |

The worlds are what a router's `/proc`, `/sys`, ubus, netlink and programs would give the collectors: `test/bench/gen.uc` writes them from a seeded generator, with the devices' fixtures as templates for the kernel's layouts, so nothing generated is committed and every machine reads the same. `typical` is a home router with Wi-Fi (12 links, 300 conntrack entries, 20 stations, 50 leases); `large` a busy one (50 links, conntrack tables of 1k, 10k and 20k entries, 200 stations, 1200 leases, ethtool's statistics of a DesignWare MAC, about 230 per port). The cases: `calibrate:vm` (ucode's speed on the machine: a loop's turn, a builtin's call, a program run under exec's watchdog), `load:base` and `load:full` (compiling the collectors, as uhttpd does when it starts), each collector of the base package and the `-full` group, nat_traffic on each conntrack table, whole scrapes of `base` and of `full` (base and the `-full` group) on both worlds, and basic auth's check of a password (`auth:`, by each format and by the cache).

uhttpd answers each request in a process forked from the one that loaded the exporter, so a scrape starts with nothing a scrape before left. A run of the benchmark does the same: each is a process of its own, timed after loading, and its memory is how far its peak (VmHWM) rose above what it held before the run. The budgets: nat_traffic's time per entry may grow at most twice from 1k to 20k entries (linear is 1), a scrape's memory and nat_traffic's at most about three times what they were measured at, a request the cache lets in a tenth of the full check of `hash_password`'s hash (about 2% everywhere), and, in the devenv unconstrained, times a few to several times what they take there; each fails the exporter as it was before the benchmark (2026.09.30-r2).

The same scrape (the typical world, base and `-full`) on each machine, with the speed of ucode's VM (`calibrate:vm`'s loop turn):

| | typical full scrape | a loop turn | a program run |
|---|---|---|---|
| devenv (Ryzen 7 7840U) | 0.10 s | 0.32 µs | 1.7 ms |
| NanoPi R3S (4×A55, OpenWrt 25.12.5) | 0.55 s | 2.0 µs | 3.2 ms |
| YunCore AX835 (MT7981, 2×A53 at 1.3 GHz) | 0.72 s | 3.0 µs | 3.4 ms |
| QEMU malta, 24Kc at 500 MIPS (`QEMU_SHIFT=1`) | 2.0 s | 9.9 µs | 5.3 ms |
| QEMU malta, 24Kc at 250 MIPS (`QEMU_SHIFT=2`) | 4.0 s | 19.7 µs | |

A limited container is like a machine whose loop turn it matches: pick `BENCH_CPUS` (with `BENCH_CPUSET=0`, one CPU) by `calibrate:vm` in the same session, as the share a container gets depends on how loaded and how fast the host's CPU is. On the laptop above, 0.35 matched the R3S (2.0 µs, and 0.54 s for the scrape), 0.22 the AP (3.1 µs), and 0.07 the 500-MIPS 24Kc (10.7 µs), though not its scrape (3.4 s): a container's programs cost what the host's do under a quota (30 ms a run there), a router's what its own kernel makes them. QEMU is the closer model of a MIPS router.

QEMU counts instructions (`-icount shift=N,sleep=on`, with the guest's RTC on the same clock), so its times are a deterministic function of the code and of N: shift 2 is exactly twice shift 1. A MIPS router's own speed is its clock times its instructions per cycle: an MT7621's 1004Kc at 880 MHz runs an interpreter at roughly 0.5 to 0.7 instructions a cycle, 450 to 600 MIPS, `QEMU_SHIFT=1`; a 24Kc at 600 to 750 MHz (QCA953x, QCA956x) at 300 to 450 MIPS, between shift 1 and shift 2. The A53 is the anchor: a loop turn takes it 3.0 µs, and the 1000-MIPS guest 4.9 µs, so it runs this code as a 1650-MIPS 24Kc would, 3 to 4 times an MT7621.

## Writing a collector

A collector is a module in `src/prometheus_exporter/collectors/<module>.uc`:

```js
'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { first_line, fields } from 'prometheus_exporter.proc';

export const meta = {
	name: 'loadavg',                          // ?collect[]=, the subpackage suffix; may hold '-'
	title: 'Load average',                    // a label of up to 40 characters, for lists and forms
	help: 'Load averages from /proc/loadavg.',
	needs: [ 'fs' ],                          // all it gets in `deps`
	// configs: [ 'dhcp' ],                   // with 'uci': the configs it may read
	// commands: [ 'nft' ],                   // with 'exec': the programs it may run
	// timeout: 10,                           // with 'exec': the seconds they get in all per scrape, unless its section says otherwise; exec_timeout by default
	// options: {                             // not enabled nor timeout, the core's
	//	directory: { default: '/var/prometheus', datatype: 'directory', help: 'The directory of the *.prom files.' },
	// },
	// paths: [ { path: '{directory}', owned: true } ], // what it reads outside /proc and /sys; see below
};

export function collect(deps, out, options) {
	let x = fields(first_line(deps.fs, '/proc/loadavg'));
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, '/proc/loadavg');

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	return Result.ok();
};
```

- `needs` are `fs` (`readfile open lsdir glob stat realpath`), `ubus` (`call`, `list`, as Results), `uci` (`deps.uci.<config>` for each of `configs`, read-only: `loaded get get_all sections foreach`, committed configuration only), `rtnl` and `nl80211` (`request` as Results, `const`), `socket` (`unix_request(path, message, timeout_ms)`, a Unix socket's whole reply as a Result), `exec` (`run(argv)` as a Result, for `commands` only; a failure's `data.status` is the exit status; the programs get the seconds of the section's `timeout`, else `meta.timeout`, else the main section's `exec_timeout` (5 by default), at most 30, in all per scrape, and one still running then is killed with every process it started and fails with COMMAND_TIMEOUT and `data.timed_out`, as does any `run` after it), `time` (`now()`) and `log` (`log(msg)`, for what a collector that succeeds still has to say). Only `prometheus_exporter.deps` touches the system.
- The exporter runs in procd's jail, which mounts what the installed and enabled collectors declare and nothing else: `/etc/config/<c>` for each of `configs`, `/bin/sh` and each of `commands` (with its libraries), and `paths`. A path may name a string option as `{option}` (`'{directory}'`), be `{ path, owned: true }` for a directory that is the exporter's alone, which the service makes when it is not there (textfile's), or be a function `(options, uci) => [ paths ]` for what a config decides (dhcp_leases' lease files). A path that is not there is mounted once it is. A socket is declared by its directory, as ujail cannot mount a socket; a shell script needs what it sources and runs (ubnt-manager).
- An option's `default` sets its type (boolean, integer or string), `help` says what it does, and `datatype`, optional, narrows its values with one of LuCI's names that the core checks: `uinteger`, `range(min,max)`, `directory` and `file` (an absolute path; it need not exist), and `regex` (one ucode compiles), which LuCI lacks. `collect` gets the options typed; a value that does not fit fails the collector with CONFIG_INVALID.
- `out.gauge|counter|untyped(name, help)` returns `(labels, value)`, which chains; `out.labels(labels)` makes labels several samples share (a device's, a station's) once, to pass instead of the object; `out.parse(text)` adds exposition text. What a collector records is kept even when it then fails.
- A scrape writes thousands of samples, and each operation of ucode's VM costs about a microsecond on a router (a regex match several, and a regex literal is compiled each time it is evaluated): keep regexes in module constants, and out of what runs per sample or per line where `index()`, `split()` on a string or `substr()` do. `make bench` shows what a collector costs (see [Benchmarks](#benchmarks)).
- `collect` returns a Result: `ok` is `node_scrape_collector_success 1`; `err` is 0 and one log line.
- An absent kernel feature is nothing to report, for any collector: where nf_conntrack is not loaded (an AP without a firewall), conntrack and nat_traffic return `ok` with no samples. A missing service or program (no unbound control socket, no `ethtool`) is an `err`.

Each collector needs a test in `test/unit/prometheus_exporter/collectors/`, and a line in the package Makefile that depends on what its `needs` and `commands` call for; `test/integration/collectors_test.uc` holds every collector to both.

## LuCI app

`luci-app-prometheus-exporter` adds two pages, and pins the exporter's release. It has its views, menu, a shared resource and an ACL, and calls the service's [ubus object](#the-ubus-object), which the base package serves.

**Services → Prometheus exporter** has two tabs:

- **Exporter**: the main section: enabled, the interface to listen on (or every address), port, keepalive, TLS files, basic auth's user and password, `compress`, `omit_zero_values`, and `exec_timeout`, the seconds the programs of a collector get. The password field is never filled: Save sends a password typed there to the object's `hash_password` and saves the hash it answers; left empty it keeps the saved hash, and emptying the user takes basic auth away, hash and all. Basic auth without the TLS files, or a user without a password, is refused. The interfaces are the ubus object's `interfaces`, netifd's logical interfaces, so a login granted this app's ACL alone, which may not read `/etc/config/network`, is offered every one; a saved interface netifd does not list is kept.
- **Collectors**: a row per installed collector: its title, with its help below; its package (base, or the removable package's name); its switch; and, when it has options, an Edit button. Edit opens LuCI's dialog, as Network → Interfaces does: a field per option by its type, with its help and its datatype, and, read-only, the configs the collector reads and what its jail mounts. A collector that runs programs has Edit for `timeout` too, its own seconds, whose placeholder is what it gets while it is empty: its own default, or `exec_timeout` as the Exporter tab has it.

The dialog's Save stages its values in uci, as LuCI's own dialogs do (they show among the unsaved changes), and Dismiss drops them; the page's Save & Apply applies them with the rest. Values are checked as they are typed, by their datatype and by the object's `validate`, as the exporter reads them, and again before the dialog stages them and before Save; nothing the exporter would refuse is saved.

What the page saves states every setting, so the file says what the exporter does without knowing its defaults:

- The Exporter tab writes every field, at its default too (`option enabled '1'`, `option omit_zero_values '0'`); only the TLS files are left out while empty, as uci holds no empty value. A field emptied is refused.
- A collector has a `config collector` section only while something differs from its defaults, its switch included: it is added when a value first differs, and removed once all are back. While it is there, it holds the switch and every option the collector declares, each written out; a collector whose row did not change keeps its section as it was.

**Status → Prometheus exporter**: whether the service is enabled and runs, where it serves `/metrics`, whether a scrape logs in and is gzipped, and each collector's result, duration and error in a scrape run on the router (outside the jail) when the page opens or on Refresh, with what the jail mounts for it.

The app's ACL grants the ubus object's four reading methods, `hash_password` to a login that may write, and `/etc/config/prometheus-exporter` to read and write; nothing else.

| | |
|---|---|
| `make browser` | the Playwright tests in `test/browser/` against LuCI in a container: the built packages, the ubus object in a real rpcd, real collectors and a stand-in for procd and netifd (`devenv/services/luci/`); `FILTER=`. Screenshots in `bin/browser/screenshots/` |
| `make pot` | `luci/po/templates/prometheus-exporter.pot`, with openwrt/luci's scanner; `make lint` fails while it is out of date |

`make lint` also parses the views (as the function bodies LuCI compiles them into) and the JSON, and fails on LuCI code that could turn data into markup (`devenv/scripts/luci-dom-lint.sh`); `make package-check` installs the app, and checks its files, its dependencies and its ACL.

## Credits

A rewrite of two packages of OpenWrt's feed, both Apache-2.0: [`prometheus-node-exporter-ucode`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-ucode), by Andre Heider (its maintainer) and contributors, and [`prometheus-node-exporter-lua`](https://github.com/openwrt/packages/tree/master/utils/prometheus-node-exporter-lua), by Jeff Schornick, Kevin Lyda, Christian Simon, Etienne Champetier (its maintainer) and contributors. Metric names and help texts follow the Prometheus [node_exporter](https://github.com/prometheus/node_exporter) and, for unbound and WireGuard, [unbound_exporter](https://github.com/letsencrypt/unbound_exporter) and [prometheus_wireguard_exporter](https://github.com/MindFlavor/prometheus_wireguard_exporter); see [docs/metrics.md](docs/metrics.md). Tests run on [utest](https://github.com/m00qek/utest). [NOTICE](NOTICE) credits each collector's upstream authors.
