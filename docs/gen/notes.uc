'use strict';

// What the generated reference pages say that the code does not hold as data:
// devenv/scripts/docs-gen.uc reads it, checks it against the code, and writes
// docs/reference/{collectors,metrics,uci-config,error-codes}.md. `make docs-gen`
// after a change here; `make lint` fails while a page is out of date, and the
// generator refuses an entry the code contradicts (a collector that is not
// there, a family a fixture already shows, an error code errors.uc lacks).

// The collectors that can have nothing to observe (Result.none), by name: when
// they do, and what is still a failure. The generator takes the reasons they
// give from the code (each Result.none's, and what prometheus.exporter.services
// says of each service they ask rc about), unless `reasons` lists them, each
// of which the code must hold. It refuses a collector here whose code has no
// Result.none, or one whose code has it and is not here.
export const nothing_to_observe = {
	'agh': {
		when: 'AdGuard Home disabled, or not installed, and nothing answers at the collector\'s `address` and `port`.',
		failure: 'AdGuard Home enabled, and nothing answering there; a reply that is not its API\'s; or one that asks for a login, which the collector does not send.',
	},
	'wifi': {
		when: 'The wireless config has no radio: the service\'s ubus object\'s `wireless` gives none.',
		failure: 'Another failed call, or an interface that is there but that nl80211 cannot answer for. An interface that is not there, because its network is not set up, is left out.',
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
		failure: 'ModemManager enabled, and `mmcli` failing or running out of time.',
	},
	'ubnt-manager': {
		when: 'ubnt-manager not installed, or `ubnt-manager -l` lists no radio.',
		failure: 'A radio that fails or does not answer.',
	},
	'wireguard': {
		when: 'rpcd has no `wireguard` object: rpcd-mod-wireguard not installed.',
		failure: 'Any other failure of `wireguard status`.',
	},
	'conntrack': {
		when: 'nf_conntrack not loaded: none of its files in `/proc/sys/net/netfilter`.',
		failure: 'Its files there, but unreadable.',
	},
	'nat_traffic': {
		when: 'nf_conntrack not loaded: no `/proc/net/nf_conntrack`.',
		failure: 'The file there, but unreadable.',
	},
	'mmc': {
		when: 'No eMMC that reports its health: no MMC host; only SD or SDIO cards, which have no `life_time` or `pre_eol_info`; or an eMMC older than 5.0, whose fields are 0 (not defined).',
		failure: 'A `life_time` or `pre_eol_info` there, but not as the kernel writes it.',
	},
	'pressure': {
		when: 'No `/proc/pressure`: a kernel without `CONFIG_PSI`, or booted with `psi=0`.',
		failure: '`/proc/pressure` there, but its `cpu`, `io` or `memory` unreadable or not as the kernel writes it.',
	},
	'snmp6': {
		when: 'No `/proc/net/dev_snmp6` (IPv6 disabled).',
		failure: 'The directory there, but unreadable.',
	},
	'diskstats': {
		when: '`device_exclude` leaves out every block device in `/proc/diskstats` (by default: flash, loop devices, zram and partitions), as on a router without a disk. Or there is no block device at all.',
		failure: '`/proc/diskstats` missing or unreadable, or a malformed line for a device it exports.',
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
		failure: 'Its `mwan3` object failing. mwan3 enabled but stopped is a reading, not a failure: `mwan3_interface_running 0`.',
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
		when: 'Neither busybox ntpd nor chronyd runs, by procd\'s instances (the service\'s ubus object\'s `time_daemons`). sysntpd runs ntpd only while `/etc/config/system` turns NTP on. When one of them runs, the collector observes that one.',
		failure: 'chronyd enabled and not running, or `chronyc` failing; busybox ntpd\'s event file unreadable.',
		// It asks rc of chronyd, but answers its own reason.
		reasons: [ 'neither ntpd nor chronyd runs' ],
	},
	'dhcp_leases': {
		when: 'dnsmasq disabled, not installed, or without an instance in `/etc/config/dhcp`; and odhcpd disabled or not installed. When one of them is enabled, the collector observes that one.',
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
		help: 'Statistic <Protocol><Field>: each field of `/proc/net/netstat`, `/proc/net/snmp` and `/proc/net/snmp6` the `fields` option matches, by default node_exporter\'s.',
		match: (n) => match(n, /^node_netstat_/),
	} ],
	'snmp6': [ {
		name: 'node_snmp6_<Protocol>_<Field>_total',
		help: 'IPv6 statistic <Protocol><Field> of the device: each field of `/proc/net/dev_snmp6/<device>` the `fields` option matches, by default 13 of about 70.',
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
	'thermal': [ {
		match: (n) => n == 'node_thermal_zone_critical_celsius',
		note: 'For a zone with trip points of type `critical` (`trip_point_<n>_type`): the lowest of them. node_exporter has no such family.',
	} ],
	'dhcp_leases': [ {
		match: (n) => n == 'node_openwrt_dhcp_pool_size',
		note: 'For each `config dhcp` section of `/etc/config/dhcp` whose DHCPv4 pool dnsmasq or odhcpd serves: its `interface` is static and has an IPv4 address, and the section has no `ignore`, `dhcpv4 \'disabled\'` or `dynamicdhcp \'0\'`. The pool is `limit` (150) addresses from `start` (100) within the subnet (or `netmask`), as dnsmasq\'s init script ranges them, less the router\'s own. `sum by (interface) (node_openwrt_dhcp_leases{family="ipv4"})` divided by it is how full the pool is.',
	} ],
	'nat_traffic': [ {
		match: (n) => n == 'node_nat_traffic_bytes',
		note: '`host` is the end of a connection on this side of the router: one of the router\'s own addresses, or an address on-link to an interface without a default route (a LAN\'s subnet, a delegated IPv6 prefix). A connection with neither end there is written as `host="other"`. Only the 2048 hosts with the most bytes get series of their own; the rest are written as `host="other"` too. `peer`, with the `peers` option only, is the other end. It makes a series per host and peer, which come and go with the connections. Only the 16384 pairs with the most bytes keep their peer; the rest are written as `peer="other"` of their host. `host="other"` always has `peer="other"`.',
	} ],
	'unbound': [ {
		match: (n) => match(n, /^unbound_(memory_|answer|rrset_|unwanted_|msg_cache|infra_cache|key_cache|response_time|rpz_)/) ||
			(match(n, /^unbound_query_/) && n != 'unbound_query_queue_time_seconds_max'),
		note: 'With `extended-statistics: yes` in unbound\'s config only (the UCI\'s `extended_stats`); see [How to monitor Unbound](../how-to/unbound.md#extended-statistics).',
	} ],
	'chrony': [ {
		match: (n) => match(n, /^chrony_serverstats_/),
		note: 'Never at `/metrics`. Written only where the collector runs outside the jail (`prometheus-exporter scrape --dir`, `collector check`, or where ujail cannot run), and only where chronyd serves time (an `allow` section in `/etc/config/chrony`).',
	} ],
};

// What a row of the scrape's own families says besides, by family: every
// entry must name a family a scrape writes.
export const scrape_notes = {
	'ucode_prometheus_exporter_scrapes_total': 'Written while the `exporter` collector is selected, in the service\'s scrapes, which keep the instance\'s ledger. Reset when the service restarts.',
	'ucode_prometheus_exporter_auth_failures_total': 'As scrapes\_total: the requests basic auth refused (401).',
	'ucode_prometheus_exporter_collector_failures_total': 'As scrapes\_total: a collector\'s failures by error code.',
	'ucode_prometheus_exporter_program_timeouts_total': 'As scrapes\_total: programs killed at their timeout.',
	'ucode_prometheus_exporter_quarantines_total': 'As scrapes\_total: times a collector\'s circuit breaker tripped.',
	'ucode_prometheus_exporter_deadline_skips_total': 'As scrapes\_total: times the deadline left a collector out or killed its program, this scrape\'s included.',
	'ucode_prometheus_exporter_collector_samples': 'Written while the `exporter` collector is selected: the samples each collector wrote in this scrape. Also in `check` and in the command line\'s scrape.',
};

// Families a collector declares that no fixture set makes it write, by
// collector name, with what the fixtures cannot show: their labels, and why
// no fixture has them. The type and help are the code's. The generator
// refuses a family here that the fixtures show, or that the collector's code
// does not declare.
export const unharvested = {
	'ethtool': [
		{ name: 'node_ethtool_info', labels: [ 'bus_info', 'device', 'driver', 'expansion_rom_version', 'firmware_version', 'version' ], why: 'From `ethtool -i <device>`, which no device\'s captures hold. Its tests run on made-up outputs (test/fixtures/synthetic/commands).' },
		{ name: 'node_network_supported_port_info', labels: [ 'device', 'type' ], why: 'From `ethtool <device>`\'s `Supported ports`, as node_ethtool_info: one series per port type (TP, AUI, BNC, MII, FIBRE, Backplane).' },
		{ name: 'node_network_supported_speed_bytes', labels: [ 'device', 'duplex', 'mode' ], why: 'From `ethtool <device>`\'s `Supported link modes`, as node_ethtool_info: one series per mode, `1000baseT/Full` as mode `1000baseT`, duplex `full`, in bytes per second.' },
		{ name: 'node_network_advertised_speed_bytes', labels: [ 'device', 'duplex', 'mode' ], why: 'From its `Advertised link modes`, as the supported ones.' },
		{ name: 'node_network_autonegotiate_supported', labels: [ 'device' ], why: 'From its `Supports auto-negotiation`, as node_ethtool_info.' },
		{ name: 'node_network_pause_supported', labels: [ 'device' ], why: 'From its `Supported pause frame use`: 1 where it says `Symmetric`.' },
		{ name: 'node_network_asymmetricpause_supported', labels: [ 'device' ], why: 'From its `Supported pause frame use`: 1 where it says `Receive-only` or `Transmit-only`.' },
		{ name: 'node_network_autonegotiate_advertised', labels: [ 'device' ], why: 'From its `Advertised auto-negotiation`.' },
		{ name: 'node_network_pause_advertised', labels: [ 'device' ], why: 'From its `Advertised pause frame use`, as the supported one.' },
		{ name: 'node_network_asymmetricpause_advertised', labels: [ 'device' ], why: 'From its `Advertised pause frame use`, as the supported one.' },
		{ name: 'node_network_autonegotiate', labels: [ 'device' ], why: 'From its `Auto-negotiation`: 1 where it is `on`.' },
	],
	'filesystem': [
		{ name: 'node_filesystem_files', labels: [ 'device', 'fstype', 'mountpoint' ], why: 'From the package\'s rpcd plugin, `ubus call prometheus-exporter.filesystem mounts`. No device\'s captures hold its inode counts: they were captured before the plugin, from rpcd\'s `file read` of `/proc/mounts` and luci\'s `getMountPoints`, which have none.' },
		{ name: 'node_filesystem_files_free', labels: [ 'device', 'fstype', 'mountpoint' ], why: 'As node_filesystem_files.' },
	],
	'exporter': [
		{ name: 'process_cpu_seconds_total', labels: [], why: 'The exporter\'s own CPU time, and its reaped scrapes\', from the serving uhttpd\'s /proc/<pid>/stat, which no capture holds.' },
		{ name: 'process_virtual_memory_bytes', labels: [], why: 'As process_cpu_seconds_total.' },
		{ name: 'process_resident_memory_bytes', labels: [], why: 'From the serving uhttpd\'s /proc/<pid>/status.' },
		{ name: 'process_start_time_seconds', labels: [], why: 'From its /proc/<pid>/stat and /proc/stat\'s btime.' },
		{ name: 'process_open_fds', labels: [], why: 'Its /proc/<pid>/fd.' },
		{ name: 'process_max_fds', labels: [], why: 'Its /proc/<pid>/limits; left out where unlimited.' },
	],
	'snmp6': [
		{ name: 'node_snmp6_ifindex', labels: [ 'device' ], why: 'Written only where the `fields` option matches `ifIndex`, which its default does not. netclass\'s `node_network_iface_id` is the same index.' },
	],
	'thermal': [
		{ name: 'node_thermal_zone_passive_celsius', labels: [ 'zone', 'type' ], why: 'Written for a zone with a passive trip point; no captured zone has one.' },
	],
	'wifi': [
		{ name: 'node_wifi_station_beacon_loss_total', labels: [ 'radio', 'device', 'mac_address' ], why: 'Written where the driver reports beacon losses; the captured one does not.' },
	],
};

// The error codes page's sections, in order, and the codes of errors.uc in
// each: the generator refuses a code errors.uc does not define, and one it
// defines that is in no section.
export const error_groups = [
	{ group: 'Collectors and their sources', codes: [ 'SOURCE_UNREADABLE', 'SOURCE_INVALID', 'COLLECTOR_CRASHED', 'COLLECTOR_NO_RESULT', 'COLLECTOR_INVALID', 'COLLECTOR_IMPURE' ] },
	{ group: 'Configuration', codes: [ 'CONFIG_INVALID', 'FILE_UNWRITABLE' ] },
	{ group: 'Capabilities', codes: [ 'NEED_MISSING', 'UBUS_CONNECT_FAILED', 'UBUS_CALL_FAILED', 'NL80211_FAILED', 'RTNL_FAILED', 'SOCKET_FAILED', 'COMMAND_NOT_ALLOWED', 'COMMAND_FAILED', 'COMMAND_TIMEOUT', 'UBUS_NOT_ALLOWED', 'PERMISSION_DENIED' ] },
	{ group: 'The scrape', codes: [ 'SCRAPE_DEADLINE', 'COLLECTOR_QUARANTINED', 'COLLECTOR_OVERRUN' ] },
	{ group: 'What the exporter enforces of a collector', codes: [ 'COLLECTOR_CANCELLED', 'COLLECTOR_KILLED', 'COLLECTOR_NOT_RUN', 'SAMPLE_LIMIT', 'FAMILY_CONFLICT' ] },
	{ group: 'Exposition text', codes: [ 'EXPOSITION_INVALID' ] },
];

// What each error code means, by code: the generator refuses a code here that
// errors.uc does not define, and one errors.uc defines that is not here.
export const errors = {
	SOURCE_UNREADABLE: 'A file the collector reads is not there or cannot be read. The detail names it.',
	SOURCE_INVALID: 'What the collector read is not what it expects: a file, a ubus reply or a program\'s output it cannot parse. The detail says where.',
	COLLECTOR_CRASHED: 'The collector died with an exception. The detail is the exception\'s first line.',
	COLLECTOR_NO_RESULT: 'The collector returned something other than a Result, or a failure without an error code (a code the collector API does not export is null). The detail says what.',
	COLLECTOR_INVALID: 'A collector module whose `meta` or `collect` is not valid: the exporter leaves it out. Or a query that names a collector that is not installed, or one that is disabled: the exporter answers 400.',
	COLLECTOR_IMPURE: 'A collector module whose top level does more than declare. The exporter leaves it out. As it loaded, the top level called a function that blocks, ends or writes to the process (`sleep`, `exit`, `print`), loads code (`require`, `loadstring`, and so the collector API\'s `exposition` functions), or changes its signals. The call is refused before it runs, in the process that first loads the module and in uhttpd\'s, and the detail names it. Or the top level changed the global scope, which is put back, or wrote over what the collector API exports, which is constant; the detail says which. Or, in `collector check` and the tests, its text runs a statement or calls a function that a declaration does not; the detail names it and its line. See [Collector interface](collector-interface.md#the-top-level).',
	CONFIG_INVALID: 'An option has a value the exporter does not take, or options that go together are not set together. The detail is `<option>: expected <what>, got <value>` (never the value of `auth_password`), or what is missing.',
	FILE_UNWRITABLE: 'The init script could not write or remove uhttpd\'s basic auth file, `/var/run/prometheus-exporter/uhttpd.conf`; or the ubus object\'s `set_password` could not write the hash\'s config, `/etc/config/prometheus-exporter-auth`.',
	NEED_MISSING: 'A capability the collector needs is not installed: `nl80211` without ucode-mod-nl80211, `socket` without ucode-mod-socket.',
	UBUS_CONNECT_FAILED: 'The exporter could not connect to ubus.',
	UBUS_CALL_FAILED: 'A ubus call failed. The detail is `<object> <method>: <status>`, as `Not found`.',
	NL80211_FAILED: 'An nl80211 request failed. The detail is the device and the kernel\'s error.',
	RTNL_FAILED: 'An rtnetlink request failed. The detail is the kernel\'s error.',
	SOCKET_FAILED: 'A Unix socket is missing; a socket refused the connection, or stopped sending its reply before the timeout; or a TCP address is not one of the device\'s own. The detail names the socket, or the address and port.',
	COMMAND_NOT_ALLOWED: 'The collector ran a program its `meta.commands` does not list.',
	COMMAND_FAILED: 'A program could not start or exited with a status other than 0. The detail is `<program>: exit status <n>` or `<program>: cannot start`.',
	COMMAND_TIMEOUT: 'A program was still running when the collector\'s seconds for programs ran out, so the exporter killed it, with every process it started. Or the collector asked to run a program after the seconds ran out.',
	UBUS_NOT_ALLOWED: 'The collector called a ubus object or method that its `meta.ubus` does not list. The exporter refuses the call without making it, in the jail or not, as the service\'s ubus ACL would. The detail is `<object> <method>`.',
	PERMISSION_DENIED: 'The system refused the service\'s user something the collector declared: a capability its process lacks, a config or a file of `/proc` it may not read, a socket it may not connect to, or a ubus call that ubusd denies, as when the service\'s ubus ACL is not loaded. The detail says what, and what grants it. The service grants each one when it starts with the collector enabled (see [The jail](jail.md#the-services-user)). Never nothing to observe.',
	SCRAPE_DEADLINE: 'The scrape\'s time was nearly spent, so the collector was not run, or a program it ran was killed at the deadline. This lets the scrape answer before the scraper gives up. The scrape logs every such collector in one line. See [About deadlines and circuit breakers](../explanation/deadlines-and-breakers.md).',
	COLLECTOR_QUARANTINED: 'The collector\'s circuit breaker is open, so it was not run in this scrape, even if the query named it. The detail says what tripped the breaker, and when the collector is tried again. Restarting the service tries it at once.',
	COLLECTOR_OVERRUN: 'What tripped a breaker: the collector took longer than its `budget`. The detail is how long it took, and its budget. The run\'s own result stands, and its breaker trips.',
	COLLECTOR_CANCELLED: 'The collector was still running at the end of its `budget`, so the exporter stopped it, with the process it ran in: a loop that never ends, or a system call that never returns. None of its samples are served, and its breaker trips. See [Collector contract](collector-contract.md).',
	COLLECTOR_KILLED: 'The process the collector ran in ended while it ran: the collector went past the memory limit, a native module crashed, or it called `exit()`. Or the scrape process itself died while the collector ran, which the next scrape finds. None of its samples are served, and its breaker trips.',
	COLLECTOR_NOT_RUN: 'The collector was not run, through no fault of its own, so its breaker stays as it was. Either the processes the scrape forked to run the collectors ended twice in a row before they ran one, which is logged once for all of them. Or the scrape\'s process was asked to stop while they ran, and ends without a reply.',
	SAMPLE_LIMIT: 'The collector wrote more samples than its `max_samples`, and was stopped there. Or it wrote more than were left of the reply\'s `max_scrape_samples`, or none were left when it would have started; in these two cases its breaker stays as it was. The detail says how many, and in which family. None of its samples are served.',
	FAMILY_CONFLICT: 'The collector wrote a family that another collector of the reply wrote first, or one the exporter keeps for itself (`node_scrape_collector_*`, `ucode_prometheus_exporter_*`). The detail names it. None of its samples are served.',
	EXPOSITION_INVALID: 'Text that is not valid Prometheus exposition format. Either a `*.prom` file of textfile, which the collector then leaves out; the detail names the line. Or something a collector wrote that would make Prometheus refuse the whole scrape: a label value or HELP text that is not valid UTF-8 or holds a NUL byte; a family name that holds one; a label name Prometheus reserves (`__name__`, or any that starts with `__`, as written or once sanitized); two label names that become one once sanitized (`if-name` and `if_name`); or labels that are neither an object nor what `out.labels()` made. The recorder stops the collector there, and the detail names the family and the label. None of its samples are served.',
};

// The command line's reference page: its usage is cli.uc's USAGE, as docopt
// parses it; each command of the usage needs an entry here, and an entry
// for a command the usage lacks is refused.
export const command = {
	intro: '`/usr/bin/prometheus-exporter`, installed by the package `ucode-prometheus-exporter-cli`. It prints a scrape on standard output, checks the service and a collector module, and hashes a password for basic auth. It parses its arguments with docopt (the `ucode-docopt` package, which only this package depends on) by the usage below, which `-h` also prints. The service needs none of it. Its init script checks the configuration with the base package\'s own `/usr/libexec/prometheus-exporter/check.uc`, which `check` also runs. The ubus object sets basic auth\'s password (`set_password`, LuCI\'s **Change password**). `apk add ucode-prometheus-exporter-cli` installs it.',
	usage: 'Up to 0.1, the command took only collectors, `prometheus-exporter [COLLECTOR...]`, and `-l` listed them. They are now `prometheus-exporter scrape [<collector>...]` and `prometheus-exporter collector list`. Given arguments the usage does not take, the command prints the usage on standard error, and exits with status `1`.',
	commands: {
		'scrape': {
			does: 'Prints a scrape on standard output, as `/metrics` answers it: of every enabled collector, or of the collectors named, in that order, by name (`ltq-dsl`) or module (`ltq_dsl`). For cron and push (see [How to push metrics](../how-to/push-metrics.md)), and for debugging.',
			notes: [
				'Each collector runs as the service runs it: in a child process of the scrape, one after the other, stopped at its `budget`, with at most its `max_samples`, and with families of its own. The scrape has the main section\'s `scrape_timeout` (see [Collector contract](collector-contract.md)).',
				'It has no ledger: nothing is quarantined, and the collectors run in their order, slow ones too, within the scrape\'s time.',
				'`--dir` loads the collectors of a directory on ucode\'s module path, such as a source tree\'s with `ucode -L src`, instead of the installed ones.',
				'It never compresses and never asks for basic auth: those are the HTTP endpoint\'s.',
			],
			exit: [ [ '0', 'The scrape was printed, whatever its collectors did.' ], [ '1', 'The scrape was refused, for a collector that is not installed or that is disabled. It says why on standard error, such as `COLLECTOR_INVALID (unknown collector \'nope\')`.' ] ],
			example: '$ prometheus-exporter scrape loadavg\n# HELP node_load1 1m load average.\n# TYPE node_load1 gauge\nnode_load1 0.72\n...\nucode_prometheus_exporter_build_info{version="0.2.0-r1"} 1',
		},
		'check': {
			does: 'Checks the configuration as the exporter and the init script read it, and describes every installed collector: its section, options, needs, and what the jail gives it. Then it runs a scrape of the enabled collectors, each as the service runs it, in the service\'s jail where ujail can run. Last, it shows what the service\'s own scrapes found: each collector quarantined, and each the deadline left out lately. `service prometheus-exporter check` runs the same, the base package\'s `/usr/libexec/prometheus-exporter/check.uc`, without the command line. With `--config`, it checks only the configuration, as `start` and `reload` do. See [Service commands](service-commands.md#check).',
			exit: [ [ '0', 'The configuration is valid, whatever the collectors did.' ], [ '1', 'It is not: a line starts `FAIL`.' ] ],
		},
		'collector list': {
			does: 'Prints a line per installed collector: its name, `enabled` or `disabled`, and what it collects.',
			notes: [ '`--dir` lists a directory\'s, as `scrape` loads them.' ],
			exit: [ [ '0', 'Always.' ] ],
			example: '$ prometheus-exporter collector list\nconntrack                enabled  Connection tracking table usage, from /proc/sys/net/netfilter.\ncpu                      enabled  CPU time per mode, from /proc/stat.\n...',
		},
		'collector check': {
			does: 'Checks a collector module before it is installed, on the device it is meant for: whether it keeps the [collector contract](collector-contract.md). It reads `<path>`, which must be `<module>.uc`, and checks its text for strict mode and its imports. It loads the module under the load timer (5 s), validates its `meta`, and runs it as the service would: in a child process, with at most its budget and its `max_samples`. It says how long the module took to load and to run, the samples it wrote, and its families. Then it checks that its text is valid exposition with each series once, and whether an installed collector or the exporter already writes one of its families.',
			notes: [
				'A line starts `ok`, `warn` or `FAIL`. Each broken rule is a `FAIL`: not in strict mode; importing a module other than `prometheus.exporter`, or calling `require`, `loadfile`, `loadstring`, `include` or `system`, with the text the loader logs (`FAIL imports fs (line 3): a collector reads files through deps.fs, with \'fs\' in meta.needs`); not loading, or not in time; a `meta` that is not valid; stopped at its budget or at the deadline, killed, over its `max_samples`, crashing, or not returning a Result; text that is not valid; a family another collector writes.',
				'A failure that comes from the device (`SOURCE_*`, `UBUS_*`, `COMMAND_FAILED`, `NEED_MISSING`) is a `warn`, and so is nothing to observe: the collector may do its job on another device.',
				'An installed module of the same name is left out of the families the module is compared with, so a new version of a collector can be checked beside the old one.',
			],
			exit: [ [ '0', 'No rule is broken.' ], [ '1', 'One is: a line starts `FAIL`.' ] ],
			example: '$ prometheus-exporter collector check /tmp/apk_updates.uc\nok   strict mode: \'use strict\' first\nok   imports: prometheus.exporter alone\nok   top level: declarations alone\nok   load: 0.004 s, of at most 5 s\nok   meta: apk_updates (APK updates), needs exec, budget 6 s, max_samples 20000\nok   run: 0.412 s, 3 samples in 2 families\nok   families: apk_upgradable_packages apk_installed_packages\nok   exposition: valid text, each series once',
		},
		'hash-password': {
			does: 'Reads a password and prints its hash: SHA-512-crypt of 1000 rounds, freshly salted, the value `auth_password` takes. From a terminal, it asks for the password without echoing it. Otherwise it reads the first line of standard input. It never prints the password, and never takes it as an argument, where `ps` would show it.',
			exit: [ [ '0', 'The hash was printed.' ], [ '1', 'No password, or one it does not accept. It says why on standard error.' ] ],
			example: '$ prometheus-exporter hash-password\nPassword:\n$6$rounds=1000$...',
		},
	},
	everywhere: [
		'It reads the committed configuration, as the service does: it leaves out a collector disabled in `/etc/config/prometheus-exporter`, and refuses a query that names one.',
		'`scrape` and `check` run the collectors in the service\'s jail where ujail can run. `scrape --dir` and `collector check` run them outside the jail, as the user who runs the command. A collector that works there and fails under the service lacks something in the jail; see [The jail](jail.md).',
		'The exporter\'s log goes to standard error, whatever its level.',
		'The version (`--version`, and the build info\'s `version`) is the package\'s, `<version>-r<release>`, or `dev` from a source tree.',
	],
};
