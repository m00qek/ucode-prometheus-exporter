'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/ethtool.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Network drivers' statistics, as node_exporter's ethtool collector
// (collector/ethtool_linux.go) names them, from `ethtool -S <device>` for every
// link (an rtnl dump) a device backs, where node_exporter asks the kernel: an
// untyped family per statistic, node_ethtool_ and the name made a metric name,
// lowercased, with the words rx and tx spelled out; seven common ones have
// node_exporter's own names, with _total, and help texts. Per device, the
// statistics are written sorted by name, and every statistic of a name two of
// them make is left out, as node_exporter does.
//
// A device whose driver has no statistics (ethtool exits non-zero: 94 for
// "no stats available") is left out. So is every link no device backs (no
// /sys/class/net/<link>/device): bridges, VLANs, WireGuard, ifb, veth. Their
// drivers have no statistics, or (ifb's per-queue counts) repeat what netdev
// has; and on a router most links are such, each costing the scrape a run of
// ethtool, which a slow CPU takes tens of milliseconds to fail.
//
// And of each such device, what node_exporter's ethtool collector has of its
// driver and its link, which `ethtool -S` does not give: `ethtool -i` is
// node_ethtool_info{bus_info, device, driver, expansion_rom_version,
// firmware_version, version} 1, and `ethtool <device>` the link modes and
// ports the device supports and advertises, as node_exporter names them:
//
//   node_network_supported_port_info{device, type}       1 for each port type
//   node_network_supported_speed_bytes{device, duplex, mode}
//   node_network_advertised_speed_bytes{device, duplex, mode}
//   node_network_autonegotiate_supported{device}         and _advertised
//   node_network_pause_supported{device}                 and _advertised
//   node_network_asymmetricpause_supported{device}       and _advertised
//   node_network_autonegotiate{device}                   autonegotiation on
//
// A link mode "1000baseT/Full" is mode 1000baseT, duplex full, its speed in
// bytes per second (125,000,000); node_exporter reads the kernel's 32 first
// modes, which stop at 10 Gb/s and leave out 2.5 and 5 Gb/s over twisted
// pair (2500baseT), and ethtool prints them all. Pause frames are supported
// or advertised where ethtool says "Symmetric", asymmetric pause where it
// says "Receive-only" or "Transmit-only". What a line of ethtool's does not
// say (a driver that reports no link modes, a radio's) is left out. The
// link's speed and duplex are netclass's node_network_speed_bytes and
// node_network_info. Three runs of ethtool a device, where node_exporter
// asks the kernel three times too.

import { Result } from 'prometheus_exporter.api';

export const meta = {
	name: 'ethtool',
	title: 'Network drivers and links',
	help: 'Network driver statistics, driver information and link modes, from ethtool -S, -i and ethtool <device>.',
	needs: [ 'rtnl', 'fs', 'exec' ],
	commands: [ 'ethtool' ],
	// Programs run for each port, three: the benchmark's 17 ports take the
	// devenv 0.1 s, the slowest collector there but nat_traffic, and a slow
	// router tens of times that. Before the ledger times it, it runs after the
	// others, so that a first scrape does not spend their time on it.
	cost: 'heavy',
};

// node_exporter's families of the common statistics: [ name, help ].
const ENTRIES = {
	rx_bytes: [ 'node_ethtool_received_bytes_total', 'Network interface bytes received' ],
	rx_dropped: [ 'node_ethtool_received_dropped_total', 'Number of received frames dropped' ],
	rx_errors: [ 'node_ethtool_received_errors_total', 'Number of received frames with errors' ],
	rx_packets: [ 'node_ethtool_received_packets_total', 'Network interface packets received' ],
	tx_bytes: [ 'node_ethtool_transmitted_bytes_total', 'Network interface bytes sent' ],
	tx_errors: [ 'node_ethtool_transmitted_errors_total', 'Number of sent frames with errors' ],
	tx_packets: [ 'node_ethtool_transmitted_packets_total', 'Network interface packets sent' ],
};

// A driver has a few hundred statistics (a DesignWare MAC about 250), each
// named with regexes: the regexes are constants (ucode compiles a literal
// each time it is evaluated), and each statistic is named once (NAMES), for
// all the devices of its driver.
const NOT_NAME = /_*[^0-9A-Za-z_]+_*/g;
const NAME = /^[0-9A-Za-z_]*$/;
const RX = /(^|_)rx(_|$)/g;
const TX = /(^|_)tx(_|$)/g;

// node_exporter's SanitizeMetricName: every run of other characters, with the
// underscores around it, one underscore. Most drivers' names have none, which
// one match tells.
export function sanitize(stat) {
	return match(stat, NAME) ? stat : replace(stat, NOT_NAME, '_');
};

// node_exporter's buildEthtoolFQName of a sanitized name: lowercased, without
// leading underscores, and rx and tx between underscores (or an end) spelled
// out. Uhttpd's process for a scrape starts with no name kept, so a scrape
// names each of a driver's statistics: a replacement is a string, not a call
// of a function per match, and a name without rx or tx takes no regex.
function fqname_of(key) {
	let name = ltrim(lc(key), '_');

	if (index(name, 'rx') >= 0)
		name = replace(name, RX, '$1received$2');
	if (index(name, 'tx') >= 0)
		name = replace(name, TX, '$1transmitted$2');

	return 'node_ethtool_' + name;
}

export function fqname(stat) {
	return fqname_of(sanitize(stat));
};

// The family of the driver's information: a statistic named so as well is
// left out, as it would write in it.
const INFO = 'node_ethtool_info';

// The words ethtool prints in `Supported ports: [ ... ]`, of the port bits
// node_exporter reads (ETHTOOL_LINK_MODE_TP_BIT and the like).
const PORTS = [ 'TP', 'AUI', 'BNC', 'MII', 'FIBRE', 'Backplane' ];

// A link mode as ethtool names it: <Mb/s>base<medium>/<Half|Full>.
const LINK_MODE = /^([0-9]+)base([A-Za-z0-9_]+)\/(Half|Full)$/;

// [ fqname, [ family name, help ] ] of each statistic named so far, up to
// NAMES_MAX of them: a driver's names are fixed, so in a process that scrapes
// many times this stops growing at what the device's drivers have.
const NAMES = {};
const NAMES_MAX = 4096;
let named = 0;

function names(stat) {
	let n = NAMES[stat];

	if (!n) {
		let key = sanitize(stat), fq = fqname_of(key);

		n = [ fq, ENTRIES[key] ?? [ fq, `Network interface ${key}` ] ];
		if (named++ < NAMES_MAX)
			NAMES[stat] = n;
	}

	return n;
}

// [ name, help ] of the family of a statistic.
export function family(stat) {
	return names(stat)[1];
};

// The [ statistic, value ] of a device to export, sorted by fqname, without
// those whose fqname another one has too.
export function exported(stats) {
	// By fqname: the statistic, or false for an fqname two of them have.
	let by_fq = {};

	for (let s in stats) {
		let fq = names(s[0])[0];
		by_fq[fq] = (fq in by_fq) ? false : s;
	}

	// sort() without a comparator compares in C, not in a ucode call per pair.
	let out = [];
	for (let fq in sort(keys(by_fq)))
		if (by_fq[fq] && fq != INFO)
			push(out, by_fq[fq]);

	return out;
};

// The statistic of a line of ethtool -S, trimmed: [ name, value ] for
// "name: value", where the name may hold ': ' itself and the value is the
// last word; null for any other line (the title). What
// match(line, /^(.+):[ \t]+([^ \t]+)$/) gives, without the regex.
function statistic(line) {
	let p = max(rindex(line, ' '), rindex(line, '\t'));

	if (p < 1)
		return null;

	// Back over the run of blanks before the value, to the ':' it needs.
	let q = p;
	while (q > 0 && index(' \t', substr(line, q - 1, 1)) >= 0)
		q--;

	return (q >= 2 && substr(line, q - 1, 1) == ':') ? [ substr(line, 0, q - 1), substr(line, p + 1) ] : null;
}

// [ [ statistic, value ], ... ] from the output of ethtool -S: a title line,
// then "  name: value" lines. A name may hold ': ' itself.
export function statistics(text) {
	let stats = [];

	for (let line in split(text ?? '', '\n')) {
		let s = statistic(trim(line));

		if (s)
			push(stats, s);
	}

	return stats;
};

// The driver's information from the output of ethtool -i, "key: value" lines,
// by key as node_exporter labels it: { driver, version, firmware_version,
// expansion_rom_version, bus_info }, '' for what it leaves empty or out.
export function driver_info(text) {
	let info = { bus_info: '', driver: '', expansion_rom_version: '', firmware_version: '', version: '' };

	for (let line in split(text ?? '', '\n')) {
		let c = index(line, ':');
		let key = (c > 0) ? replace(trim(substr(line, 0, c)), '-', '_') : null;

		if (key in keys(info))
			info[key] = trim(substr(line, c + 1));
	}

	return info;
};

// What `ethtool <device>` says of the link, by what node_exporter has of it:
// { supported: { ports, modes, pause, asymmetric_pause, autonegotiate },
// advertised: { modes, pause, asymmetric_pause, autonegotiate },
// autonegotiate }, a mode [ mode, duplex, Mb/s ]. What it does not say is
// null, or an empty list. A line is "Name: value", and the link modes go on
// over lines of their own.
export function link_settings(text) {
	let s = {
		supported: { ports: [], modes: [], pause: null, asymmetric_pause: null, autonegotiate: null },
		advertised: { modes: [], pause: null, asymmetric_pause: null, autonegotiate: null },
		autonegotiate: null,
	};
	let modes = null;

	for (let line in split(text ?? '', '\n')) {
		let t = trim(line);
		let c = index(t, ':');
		let value = t;

		if (c >= 0) {
			let name = substr(t, 0, c);

			value = trim(substr(t, c + 1));
			modes = (name == 'Supported link modes') ? s.supported.modes : (name == 'Advertised link modes') ? s.advertised.modes : null;

			if (name == 'Supported ports')
				s.supported.ports = filter(split(replace(value, /[\[\]]/g, ' '), /[ \t]+/), (w) => w in PORTS);
			else if (name == 'Supported pause frame use' || name == 'Advertised pause frame use') {
				let to = (substr(name, 0, 1) == 'S') ? s.supported : s.advertised;

				to.pause = index(value, 'Symmetric') >= 0;
				to.asymmetric_pause = index(value, 'Receive-only') >= 0 || index(value, 'Transmit-only') >= 0;
			}
			else if (name == 'Supports auto-negotiation')
				s.supported.autonegotiate = (value == 'Yes');
			else if (name == 'Advertised auto-negotiation')
				s.advertised.autonegotiate = (value == 'Yes');
			else if (name == 'Auto-negotiation')
				s.autonegotiate = (value == 'on');
		}

		if (modes == null)
			continue;

		for (let w in split(value, /[ \t]+/)) {
			let m = match(w, LINK_MODE);

			if (m)
				push(modes, [ `${m[1]}base${m[2]}`, lc(m[3]), +m[1] ]);
		}
	}

	return s;
};

// Whether a device backs the link `dev`: what has a driver that may have
// statistics.
export function backed(fs, dev) {
	return fs.stat(`/sys/class/net/${dev}/device`) != null;
};

// ethtool itself is missing or cannot run, as opposed to a driver without
// statistics: the shell's 126 and 127, or no process at all; or it ran out of
// time, which the links after it would find spent.
function cannot_run(res) {
	return res.data?.status == null || res.data.status in [ 126, 127 ];
}

export function collect(deps, out) {
	let c = deps.rtnl.const;
	let links = deps.rtnl.request(c.RTM_GETLINK, c.NLM_F_DUMP);

	if (!links.ok)
		return links;

	let families = {};
	// node_exporter's families and help of the driver and the link.
	let info = out.gauge('node_ethtool_info', 'A metric with a constant \'1\' value labeled by bus_info, device, driver, expansion_rom_version, firmware_version, version.');
	let port = out.gauge('node_network_supported_port_info', 'Type of ports or PHYs supported by network device');
	let speeds = {
		supported: out.gauge('node_network_supported_speed_bytes', 'Combination of speeds and features supported by network device'),
		advertised: out.gauge('node_network_advertised_speed_bytes', 'Combination of speeds and features offered by network device'),
	};
	let flags = {
		supported: {
			autonegotiate: out.gauge('node_network_autonegotiate_supported', 'If this port device supports autonegotiate'),
			pause: out.gauge('node_network_pause_supported', 'If this port device supports pause frames'),
			asymmetric_pause: out.gauge('node_network_asymmetricpause_supported', 'If this port device supports asymmetric pause frames'),
		},
		advertised: {
			autonegotiate: out.gauge('node_network_autonegotiate_advertised', 'If this port device offers autonegotiate'),
			pause: out.gauge('node_network_pause_advertised', 'If this port device offers pause capability'),
			asymmetric_pause: out.gauge('node_network_asymmetricpause_advertised', 'If this port device offers asymmetric pause capability'),
		},
	};
	let autonegotiate = out.gauge('node_network_autonegotiate', 'If this port is using autonegotiate');

	for (let link in links.data ?? []) {
		let device = link.dev ?? link.ifname;

		if (device == null || !backed(deps.fs, device))
			continue;

		let labels = out.labels({ device });
		let res = deps.exec.run([ 'ethtool', '-S', device ]);

		if (res.ok) {
			for (let s in exported(statistics(res.data))) {
				let f = family(s[0]);

				families[f[0]] ??= out.untyped(f[0], f[1]);
				families[f[0]](labels, s[1]);
			}
		} else if (cannot_run(res))
			return res;

		res = deps.exec.run([ 'ethtool', '-i', device ]);
		if (res.ok) {
			let d = driver_info(res.data);

			info({ bus_info: d.bus_info, device, driver: d.driver, expansion_rom_version: d.expansion_rom_version,
				firmware_version: d.firmware_version, version: d.version }, 1);
		} else if (cannot_run(res))
			return res;

		res = deps.exec.run([ 'ethtool', device ]);
		if (!res.ok) {
			if (cannot_run(res))
				return res;
			continue;
		}

		let s = link_settings(res.data);

		for (let type in s.supported.ports)
			port({ device, type }, 1);

		for (let which in [ 'supported', 'advertised' ]) {
			for (let m in s[which].modes)
				speeds[which]({ device, duplex: m[1], mode: m[0] }, m[2] * 125000);
			for (let flag, record in flags[which])
				if (s[which][flag] != null)
					record(labels, s[which][flag]);
		}

		if (s.autonegotiate != null)
			autonegotiate(labels, s.autonegotiate);
	}

	return Result.ok();
};
