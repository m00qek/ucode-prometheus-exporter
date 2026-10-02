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
// ethtool, which a slow CPU takes tens of milliseconds to fail. node_exporter's
// link information (node_network_supported_speed_bytes and the like,
// node_ethtool_info) is not in `ethtool -S`, so this collector does not export
// it.

import { Result } from 'prometheus_exporter.api';

export const meta = {
	name: 'ethtool',
	title: 'Network driver statistics',
	help: 'Network driver statistics from ethtool -S.',
	needs: [ 'rtnl', 'fs', 'exec' ],
	commands: [ 'ethtool' ],
	// A program run for each port: the benchmark's 17 ports take the devenv
	// 0.13 s, the slowest collector there but nat_traffic, and a slow router
	// tens of times that. Before the ledger times it, it runs after the
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
		if (by_fq[fq])
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

	for (let link in links.data ?? []) {
		let device = link.dev ?? link.ifname;

		if (device == null || !backed(deps.fs, device))
			continue;

		let res = deps.exec.run([ 'ethtool', '-S', device ]);
		if (!res.ok) {
			if (cannot_run(res))
				return res;
			continue;
		}

		let labels = out.labels({ device });

		for (let s in exported(statistics(res.data))) {
			let f = family(s[0]);

			families[f[0]] ??= out.untyped(f[0], f[1]);
			families[f[0]](labels, s[1]);
		}
	}

	return Result.ok();
};
