'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/ethtool.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Network drivers' statistics, as node_exporter's ethtool collector
// (collector/ethtool_linux.go) names them, from `ethtool -S <device>` for every
// link (an rtnl dump) where node_exporter asks the kernel: an untyped family per
// statistic, node_ethtool_ and the name made a metric name, lowercased, with
// the words rx and tx spelled out; seven common ones have node_exporter's own
// names, with _total, and help texts. Per device, the statistics are written
// sorted by name, and every statistic of a name two of them make is left out,
// as node_exporter does.
//
// A device whose driver has no statistics (ethtool exits non-zero: 94 for
// "no stats available") is left out. node_exporter's link information
// (node_network_supported_speed_bytes and the like, node_ethtool_info) is not
// in `ethtool -S`, so this collector does not export it.

import * as Result from 'prometheus_exporter.result';

export const meta = {
	name: 'ethtool',
	title: 'Network driver statistics',
	help: 'Network driver statistics from ethtool -S.',
	needs: [ 'rtnl', 'exec' ],
	commands: [ 'ethtool' ],
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

// node_exporter's SanitizeMetricName: every run of other characters, with the
// underscores around it, one underscore.
export function sanitize(stat) {
	return replace(stat, /_*[^0-9A-Za-z_]+_*/g, '_');
};

// node_exporter's buildEthtoolFQName: the sanitized name lowercased, without
// leading underscores, and rx and tx between underscores (or an end) spelled out.
export function fqname(stat) {
	let name = ltrim(lc(sanitize(stat)), '_');

	name = replace(name, /(^|_)rx(_|$)/g, (m, a, b) => a + 'received' + b);
	name = replace(name, /(^|_)tx(_|$)/g, (m, a, b) => a + 'transmitted' + b);

	return 'node_ethtool_' + name;
};

// [ name, help ] of the family of a statistic.
export function family(stat) {
	let key = sanitize(stat);

	return ENTRIES[key] ?? [ fqname(stat), `Network interface ${key}` ];
};

// The [ statistic, value ] of a device to export, sorted by fqname, without
// those whose fqname another one has too.
export function exported(stats) {
	let count = {};

	for (let s in stats)
		count[fqname(s[0])] = (count[fqname(s[0])] ?? 0) + 1;

	return sort(filter(stats, (s) => count[fqname(s[0])] == 1),
		(a, b) => fqname(a[0]) < fqname(b[0]) ? -1 : fqname(a[0]) > fqname(b[0]) ? 1 : 0);
};

// [ [ statistic, value ], ... ] from the output of ethtool -S: a title line,
// then "  name: value" lines. A name may hold ': ' itself.
export function statistics(text) {
	let stats = [];

	for (let line in split(text ?? '', '\n')) {
		let m = match(trim(line), /^(.+):[ \t]+([^ \t]+)$/);

		if (m)
			push(stats, [ m[1], m[2] ]);
	}

	return stats;
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

		if (device == null)
			continue;

		let res = deps.exec.run([ 'ethtool', '-S', device ]);
		if (!res.ok) {
			if (cannot_run(res))
				return res;
			continue;
		}

		for (let s in exported(statistics(res.data))) {
			let f = family(s[0]);

			families[f[0]] ??= out.untyped(f[0], f[1]);
			families[f[0]]({ device }, s[1]);
		}
	}

	return Result.ok();
};
