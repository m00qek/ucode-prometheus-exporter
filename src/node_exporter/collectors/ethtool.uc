'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/ethtool.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Network drivers' statistics, as the Lua exporter's ethtool collector, from
// `ethtool -S <device>` for every link (an rtnl dump) instead of the
// ethtool-lua module: an untyped family per statistic, named by the Lua
// collector's map where it has the name, else node_ethtool_ and the name
// made a metric name, lowercased, with rx and tx spelled out.
//
// A device whose driver has no statistics (ethtool exits non-zero: 94 for
// "no stats available") is left out. The Lua collector's link information
// (supported and advertised speeds, pause, autonegotiation) is not in
// `ethtool -S`, so this collector does not export it.

import * as Result from 'node_exporter.result';

export const meta = {
	name: 'ethtool',
	help: 'Network driver statistics from ethtool -S.',
	needs: [ 'rtnl', 'exec' ],
	commands: [ 'ethtool' ],
};

// The Lua collector's names for the common statistics.
const FQNAMES = {
	rx_bytes: 'node_ethtool_received_bytes_total',
	rx_dropped: 'node_ethtool_received_dropped_total',
	rx_errors: 'node_ethtool_received_errors_total',
	rx_packets: 'node_ethtool_received_packets_total',
	tx_bytes: 'node_ethtool_transmitted_bytes_total',
	tx_errors: 'node_ethtool_transmitted_errors_total',
	tx_packets: 'node_ethtool_transmitted_packets_total',
};

const WORDS = { rx: 'received', tx: 'transmitted' };

// The family of statistic `stat`, as the Lua collector names it: every run of
// other characters (with the underscores around it) one underscore, lowercase,
// no leading underscores, and the words rx and tx spelled out.
export function fqname(stat) {
	if (FQNAMES[stat])
		return FQNAMES[stat];

	let name = lc(replace(stat, /_*[^0-9A-Za-z_]+_*/g, '_'));
	name = replace(name, /^_+/, '');
	name = replace(name, /[a-z]+/g, (w) => WORDS[w] ?? w);

	return 'node_ethtool_' + name;
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
// statistics: the shell's 126 and 127, or no process at all.
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

		// Two statistics may make one name: the first is kept.
		let seen = {};
		for (let s in statistics(res.data)) {
			let name = fqname(s[0]);

			if (seen[name])
				continue;
			seen[name] = true;

			families[name] ??= out.untyped(name, `Driver statistic ${s[0]}, from ethtool -S.`);
			families[name]({ device }, s[1]);
		}
	}

	return Result.ok();
};
