'use strict';

// What the generated reference pages say that the code does not hold as data:
// devenv/scripts/docs-gen.uc reads it, checks it against the code, and writes
// docs/reference/{collectors,metrics,uci-config,error-codes}.md. `make docs-gen`
// after a change here; `make lint` fails while a page is out of date, and the
// generator refuses an entry the code contradicts (a collector that is not
// there, a family a fixture already shows, an error code errors.uc lacks).

// The collectors that can have nothing to observe (Result.none), by name: when
// they do, and what is still a failure. The generator takes the reasons they
// give from the code (each Result.none's, and what prometheus_exporter.services
// says of each service they ask rc about), unless `reasons` lists them, each
// of which the code must hold. It refuses a collector here whose code has no
// Result.none, or one whose code has it and is not here.
export const nothing_to_observe = {
	'wifi': {
		when: 'No `network.wireless` object, or one without radios.',
		failure: 'Another failed call; an interface nl80211 cannot answer for.',
	},
	'wifi_stations': {
		when: 'As wifi, or no radio with an interface.',
		failure: 'As wifi.',
	},
	'hostapd_stations': {
		when: 'As wifi, or no `hostapd.<ifname>` object for any interface.',
		failure: 'A hostapd object that does not answer.',
	},
	'hostapd_ubus_stations': {
		when: 'No `hostapd.*` object.',
		failure: 'A hostapd object that does not answer.',
	},
	'ltq-dsl': {
		when: 'No `dsl` object.',
		failure: 'A `dsl` object that does not answer.',
	},
	'realtek-poe': {
		when: 'No `poe` object.',
		failure: 'A `poe` object that does not answer.',
	},
	'modemmanager': {
		when: 'ModemManager disabled or not installed, or it lists no modem.',
		failure: '`mmcli` failing or running out of time with ModemManager enabled.',
	},
	'ubnt-manager': {
		when: '`ubnt-manager -l` lists no radio.',
		failure: 'A radio that fails or does not answer.',
	},
	'conntrack': {
		when: 'nf_conntrack not loaded: none of its files in `/proc/sys/net/netfilter`.',
		failure: 'Its files there and unreadable.',
	},
	'nat_traffic': {
		when: 'nf_conntrack not loaded: no `/proc/net/nf_conntrack`.',
		failure: 'The file there and unreadable.',
	},
	'snmp6': {
		when: 'No `/proc/net/dev_snmp6` (IPv6 disabled).',
		failure: 'The directory there and unreadable.',
	},
	'diskstats': {
		when: 'Every block device in `/proc/diskstats` is one `device_exclude` leaves out (by default flash, loop devices, zram and partitions): a router without a disk. Or no block device at all.',
		failure: '`/proc/diskstats` not there or unreadable; a line of a device it exports that is malformed.',
	},
	'dnsmasq': {
		when: 'dnsmasq disabled, or not installed.',
		failure: 'dnsmasq enabled, and its `dnsmasq` object missing or failing.',
	},
	'unbound': {
		when: 'unbound disabled, or not installed.',
		failure: 'unbound enabled, and its control socket not answering.',
	},
	'mwan3': {
		when: 'mwan3 disabled, or not installed.',
		failure: 'Its `mwan3` object failing. Enabled and stopped is a reading: `mwan3_interface_running 0`.',
	},
	'dawn': {
		when: 'DAWN disabled, or not installed.',
		failure: 'DAWN enabled, and its `dawn` object missing or failing.',
	},
	'bmx7': {
		when: 'bmx7 disabled, or not installed.',
		failure: 'bmx7 enabled, and its status files unreadable.',
	},
	'chrony': {
		when: 'chronyd disabled, or not installed.',
		failure: 'chronyd enabled, and `chronyc` failing (chronyd stopped).',
	},
	'timesync': {
		when: 'Neither busybox ntpd nor chronyd runs, as procd\'s instances say: sysntpd runs ntpd only while `/etc/config/system` turns NTP on. With one running, it observes that one.',
		failure: 'chronyd enabled and not running, or `chronyc` failing; busybox ntpd\'s event file unreadable.',
		// It asks rc of chronyd, but answers its own reason.
		reasons: [ 'neither ntpd nor chronyd runs' ],
	},
	'dhcp_leases': {
		when: 'dnsmasq (or no dnsmasq instance in `/etc/config/dhcp`) and odhcpd both disabled or not installed. With one of them enabled, it observes that one.',
		failure: 'An enabled server that is not there: no dnsmasq lease file, odhcpd not on ubus.',
	},
};

// What the metrics page calls each fixture set of test/fixtures/, which are
// named after devices: a device's own name stays out of the docs. The
// generator refuses a set without a name here, and a name for no set.
export const capture_sets = {
	'caju-ap': 'an access point',
	'caju-router': 'a router',
	'seriguela-router': 'a second router',
	'synthetic': 'made-up captures',
};

// The paths a collector's meta.paths gives by a function, which the jail
// works out from its options and configs, by collector name. The generator
// refuses a function path without an entry here.
export const computed_paths = {
	'dhcp_leases': 'The lease file of each `dnsmasq` section of `/etc/config/dhcp`: its `leasefile`, or `/tmp/dhcp.leases`.',
	'unbound': 'The directory of the `socket` option: `/var/lib/unbound` by default.',
};

// Families whose names hold what the source reports, listed as one row each,
// by collector: `match(name)` takes the families of the row, `name` and `help`
// describe them, and `type` and `labels`, when given, replace what the
// fixtures show. Every row must take a family the fixtures show.
export const metric_patterns = {
	'ethtool': [ {
		name: 'node_ethtool_<statistic>',
		help: 'Network interface <statistic>: each other statistic of `ethtool -S`, named as node_exporter names it.',
		// Not node_exporter's seven common statistics, which have names of their own.
		match: (n) => match(n, /^node_ethtool_/) &&
			!match(n, /^node_ethtool_received_(bytes|dropped|errors|packets)_total$/) &&
			!match(n, /^node_ethtool_transmitted_(bytes|errors|packets)_total$/),
	} ],
	'meminfo': [ {
		name: 'node_memory_<Field>_bytes',
		help: 'Memory information field <Field>_bytes: each field of `/proc/meminfo` in kB, in bytes.',
		match: (n) => match(n, /^node_memory_.*_bytes$/),
	}, {
		name: 'node_memory_<Field>',
		help: 'Memory information field <Field>: each field without a unit, the HugePages counts.',
		match: (n) => match(n, /^node_memory_/) && !match(n, /_bytes$/),
	} ],
	'netstat': [ {
		name: 'node_netstat_<Protocol>_<Field>',
		help: 'Statistic <Protocol><Field>: each of `/proc/net/netstat`, `/proc/net/snmp` and `/proc/net/snmp6`.',
		match: (n) => match(n, /^node_netstat_/),
	} ],
	'snmp6': [ {
		name: 'node_snmp6_<Protocol>_<Field>_total',
		help: 'IPv6 statistic <Protocol><Field> of the device: each of `/proc/net/dev_snmp6/<device>`.',
		match: (n) => match(n, /^node_snmp6_.*_total$/),
	} ],
	'vmstat': [ {
		name: 'node_vmstat_<field>',
		help: '/proc/vmstat information field <field>: each field the `fields` option matches.',
		match: (n) => match(n, /^node_vmstat_/),
	} ],
	'modemmanager': [ {
		name: 'modemmanager_signal_<technology>_<measure>[_<unit>]',
		help: 'The <technology> <measure> of the modem signal: `_dbm` for rssi, rsrp, rscp and io, `_db` for rsrq, snr, sinr and ecio, `_seconds` for the refresh rate, none for a measure not known.',
		match: (n) => match(n, /^modemmanager_signal_/) && n != 'modemmanager_signal_quality_ratio',
	} ],
	'textfile': [ {
		name: '<the files\' families>',
		type: 'theirs',
		labels: 'theirs',
		help: 'The families of the `*.prom` files, as they are.',
		match: (n) => !match(n, /^node_textfile_/),
	} ],
};

// What a family's row says besides, by collector: `note` for each family
// `match(name)` takes. Every entry must take a family the fixtures show.
export const family_notes = {
	'chrony': [ {
		match: (n) => match(n, /^chrony_serverstats_/),
		note: 'Never at `/metrics`: written outside the jail only, as by the `prometheus-exporter` command, where chronyd serves time (an `allow` section in `/etc/config/chrony`).',
	} ],
};

// Families a collector declares that no fixture set makes it write, by
// collector name, with what the fixtures cannot show: their labels, and why
// no fixture has them. The type and help are the code's. The generator
// refuses a family here that the fixtures show, or that the collector's code
// does not declare.
export const unharvested = {
	'exporter': [
		{ name: 'process_cpu_seconds_total', labels: [], why: 'The exporter\'s own, from the serving uhttpd\'s /proc/<pid>/stat, which no capture holds: its CPU and its reaped scrapes\'.' },
		{ name: 'process_virtual_memory_bytes', labels: [], why: 'As process_cpu_seconds_total.' },
		{ name: 'process_resident_memory_bytes', labels: [], why: 'From the serving uhttpd\'s /proc/<pid>/status.' },
		{ name: 'process_start_time_seconds', labels: [], why: 'From its /proc/<pid>/stat and /proc/stat\'s btime.' },
		{ name: 'process_open_fds', labels: [], why: 'Its /proc/<pid>/fd.' },
		{ name: 'process_max_fds', labels: [], why: 'Its /proc/<pid>/limits; left out where unlimited.' },
		{ name: 'ucode_prometheus_exporter_scrapes_total', labels: [], why: 'Counted in the instance\'s ledger, which only the handler\'s scrapes keep; reset when the service restarts.' },
		{ name: 'ucode_prometheus_exporter_auth_failures_total', labels: [], why: 'As scrapes_total: the requests basic auth refused (401).' },
		{ name: 'ucode_prometheus_exporter_collector_failures_total', labels: [ 'collector', 'reason' ], why: 'As scrapes_total: a collector\'s failures by error code.' },
		{ name: 'ucode_prometheus_exporter_program_timeouts_total', labels: [ 'collector' ], why: 'As scrapes_total: programs killed at their timeout.' },
		{ name: 'ucode_prometheus_exporter_quarantines_total', labels: [ 'collector' ], why: 'As scrapes_total: times a collector\'s circuit breaker tripped.' },
		{ name: 'ucode_prometheus_exporter_deadline_skips_total', labels: [ 'collector' ], why: 'As scrapes_total: times the deadline left a collector out or killed its program.' },
		{ name: 'ucode_prometheus_exporter_collector_samples', labels: [ 'collector' ], why: 'This scrape\'s: the samples each collector that ran before it wrote.' },
	],
	'thermal': [
		{ name: 'node_thermal_zone_passive_celsius', labels: [ 'zone', 'type' ], why: 'Written for a zone with a passive trip point; no captured zone has one.' },
	],
	'wifi': [
		{ name: 'node_wifi_station_beacon_loss_total', labels: [ 'radio', 'device', 'mac_address' ], why: 'Written where the driver reports beacon losses; the captured one does not.' },
	],
	'wifi_stations': [
		{ name: 'node_wifi_station_beacon_loss_total', labels: [ 'device', 'mac_address' ], why: 'As wifi.' },
	],
};

// What each error code means, by code: the generator refuses a code here that
// errors.uc does not define, and one errors.uc defines that is not here.
export const errors = {
	SOURCE_UNREADABLE: 'A file the collector reads is not there or cannot be read. The detail names it.',
	SOURCE_INVALID: 'What the collector read is not what it expects: a file, a ubus reply or a program\'s output it cannot parse. The detail says where.',
	COLLECTOR_CRASHED: 'The collector died with an exception. The detail is the exception\'s first line.',
	COLLECTOR_NO_RESULT: 'The collector returned something other than a Result. The detail says what.',
	COLLECTOR_INVALID: 'A collector module that cannot be loaded as one (its `meta` or `collect`), which the exporter leaves out; or a query that names a collector that is not installed, or one that is disabled, which is answered 400.',
	CONFIG_INVALID: 'An option has a value the exporter does not take, or options that go together are not set together. The detail is `<option>: expected <what>, got <value>` (never the value of `auth_password`), or what is missing.',
	FILE_UNWRITABLE: 'The init script could not write or remove uhttpd\'s basic auth file, `/var/run/prometheus-exporter/uhttpd.conf`.',
	NEED_MISSING: 'A capability the collector needs is not installed: `nl80211` without ucode-mod-nl80211, `socket` without ucode-mod-socket.',
	UBUS_CONNECT_FAILED: 'The exporter could not connect to ubus.',
	UBUS_CALL_FAILED: 'A ubus call failed. The detail is `<object> <method>: <status>`, as `Not found`.',
	NL80211_FAILED: 'An nl80211 request failed. The detail is the device and the kernel\'s error.',
	RTNL_FAILED: 'An rtnetlink request failed. The detail is the kernel\'s error.',
	SOCKET_FAILED: 'A Unix socket is missing, refused the connection, or sent no more of its reply in time. The detail names the socket.',
	COMMAND_NOT_ALLOWED: 'The collector ran a program its `meta.commands` does not list.',
	COMMAND_FAILED: 'A program could not start or exited with a status other than 0. The detail is `<program>: exit status <n>` or `<program>: cannot start`.',
	COMMAND_TIMEOUT: 'A program was still running when the collector\'s seconds for programs were spent, and was killed with every process it started; or the collector asked to run one after they were spent.',
	SCRAPE_DEADLINE: 'The scrape\'s time was nearly spent: the collector was not run, or a program it ran was killed at the deadline, so that the scrape answers before the scraper gives up. The scrape logs every such collector in one line. See [About deadlines and circuit breakers](../explanation/deadlines-and-breakers.md).',
	COLLECTOR_QUARANTINED: 'The collector\'s circuit breaker is open: it was not run in this scrape, even if the query named it. The detail says what tripped the breaker and when the collector is tried again; a restart of the service tries it at once.',
	COLLECTOR_OVERRUN: 'What tripped a breaker: the collector took longer than its `budget`. The detail is how long it took and its budget. The run itself counts as it went; its breaker trips.',
	COLLECTOR_CANCELLED: 'The collector was still running at the end of its `budget`, and was stopped with the process it ran in: a loop that never ends, or a system call that never returns. None of its samples are served, and its breaker trips. See [Collector contract](collector-contract.md).',
	COLLECTOR_KILLED: 'The process the collector ran in ended while it ran: it went past the memory limit, a native module crashed, or it called `exit()`; or the scrape process itself died while it ran, which the next scrape finds. None of its samples are served, and its breaker trips.',
	SAMPLE_LIMIT: 'The collector wrote more samples than its `max_samples`, and was stopped there. The detail says how many and in which family. None of its samples are served.',
	FAMILY_CONFLICT: 'The collector wrote a family that another collector of the reply wrote first, or one the exporter keeps for itself (`node_scrape_collector_*`, `ucode_prometheus_exporter_*`). The detail names it. None of its samples are served.',
	EXPOSITION_INVALID: 'Text that is not valid Prometheus exposition format: a `*.prom` file of textfile, which the collector then leaves out. The detail names the line.',
};

// The command line's reference page: its usage is cli.uc's USAGE, as docopt
// parses it; each command of the usage needs an entry here, and an entry
// for a command the usage lacks is refused.
export const command = {
	intro: '`/usr/bin/prometheus-exporter`, which the base package installs: a scrape on standard output, the checks of the service and of a collector module, and the hash of a password for basic auth. It parses its arguments with docopt (the `ucode-docopt` package) by the usage below, which is also what `-h` prints.',
	usage: 'Up to 0.1, the command took the collectors alone, `prometheus-exporter [COLLECTOR...]`, and `-l` listed them: they are `prometheus-exporter scrape [<collector>...]` and `prometheus-exporter collector list` now. Arguments the usage does not take print it on standard error, with exit status `1`.',
	commands: {
		'scrape': {
			does: 'Prints a scrape on standard output, as `/metrics` answers it: of every enabled collector, or of those named, by name (`ltq-dsl`) or module (`ltq_dsl`), in that order. For cron and push (see [How to push metrics](../how-to/push-metrics.md)), and for debugging.',
			notes: [
				'Each collector runs as the service runs it: in a process of its own, stopped at its `budget`, at most its `max_samples`, its families its own; the scrape has the main section\'s `scrape_timeout` (see [Collector contract](collector-contract.md)).',
				'It has no ledger: nothing is quarantined, and the collectors run in their order, slow ones too, within the scrape\'s time.',
				'`--dir` loads the collectors of a directory on ucode\'s module path, as a source tree\'s with `ucode -L src`, not the installed ones.',
				'It never compresses and never asks for basic auth: those are the HTTP endpoint\'s.',
			],
			exit: [ [ '0', 'The scrape was printed, whatever its collectors did.' ], [ '1', 'The scrape was refused: a collector that is not installed, or one that is disabled, said on standard error as `COLLECTOR_INVALID (unknown collector \'nope\')`.' ] ],
			example: '$ prometheus-exporter scrape loadavg\n# HELP node_load1 1m load average.\n# TYPE node_load1 gauge\nnode_load1 0.72\n...\nucode_prometheus_exporter_build_info{version="0.2.0-r1"} 1',
		},
		'check': {
			does: 'Checks the configuration as the exporter and the init script read it, describes every installed collector (its section, options, needs and what the jail gives it), and runs a scrape of the enabled ones, outside the jail, each as the service runs it; then what the service\'s own scrapes found: each collector quarantined, and each the deadline left out lately. `service prometheus-exporter check` runs it. With `--config`, the configuration alone, as `start` and `reload` check it. See [Service commands](service-commands.md#check).',
			exit: [ [ '0', 'The configuration is valid, whatever the collectors did.' ], [ '1', 'It is not: a line starts `FAIL`.' ] ],
		},
		'collector list': {
			does: 'Prints a line per installed collector: its name, `enabled` or `disabled`, and what it collects.',
			notes: [ '`--dir` lists a directory\'s, as `scrape` loads them.' ],
			exit: [ [ '0', 'Always.' ] ],
			example: '$ prometheus-exporter collector list\nconntrack                enabled  Connection tracking table usage, from /proc/sys/net/netfilter.\ncpu                      enabled  CPU time per mode, from /proc/stat.\n...',
		},
		'collector check': {
			does: 'Checks a collector module before it is installed, on the device it is meant for: whether it keeps the [collector contract](collector-contract.md). It reads `<path>`, which must be `<module>.uc`, loads it under the load timer (5 s), validates its `meta`, and runs it as the service would, in a process of its own, at most its budget and its `max_samples`. It says how long it took to load and to run, the samples it wrote and its families, and then whether its text is valid exposition, each series once, and whether a family is one an installed collector or the exporter writes.',
			notes: [
				'A line starts `ok`, `warn` or `FAIL`. A rule broken is `FAIL`: not in strict mode; not loading, or not in time; a `meta` that is not valid; stopped at its budget or at the deadline, killed, over its `max_samples`, crashing, or not returning a Result; text that is not valid; a family another writes.',
				'A failure that is the device\'s (`SOURCE_*`, `UBUS_*`, `COMMAND_FAILED`, `NEED_MISSING`) is `warn`, and so is nothing to observe: it may do its job on another device.',
				'A module of the same name already installed is left out of the families it is compared with: a new version of a collector can be checked beside the old.',
			],
			exit: [ [ '0', 'No rule is broken.' ], [ '1', 'One is: a line starts `FAIL`.' ] ],
			example: '$ prometheus-exporter collector check /tmp/apk_updates.uc\nok   strict mode: \'use strict\' first\nok   load: 0.004 s, of at most 5 s\nok   meta: apk_updates (APK updates), needs exec, budget 6 s, max_samples 20000\nok   run: 0.412 s, 3 samples in 2 families\nok   families: apk_upgradable_packages apk_installed_packages\nok   exposition: valid text, each series once',
		},
		'hash-password': {
			does: 'Reads a password and prints its hash, SHA-512-crypt of 1000 rounds, freshly salted: the value `auth_password` takes. From a terminal it asks for the password, which it does not echo; otherwise it reads the first line of standard input. The password is never printed, nor taken as an argument, where `ps` would show it.',
			exit: [ [ '0', 'The hash was printed.' ], [ '1', 'No password, or one it does not take: why, on standard error.' ] ],
			example: '$ prometheus-exporter hash-password\nPassword:\n$6$rounds=1000$...',
		},
	},
	everywhere: [
		'It reads the committed configuration, as the service does: a collector disabled in `/etc/config/prometheus-exporter` is left out, and naming it is refused.',
		'It runs as the user who runs it, outside the jail: a collector that works here and fails under the service lacks something in the jail; see [The jail](jail.md).',
		'What the exporter logs goes to standard error, whatever its level.',
		'The version (`--version`, and the build info\'s `version`) is the package\'s, `<version>-r<release>`, or `dev` from a source tree.',
	],
};
