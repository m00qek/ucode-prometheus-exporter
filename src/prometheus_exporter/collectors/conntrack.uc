'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/conntrack.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.
// The statistics are node_exporter's (collector/conntrack_linux.go).

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { first_line, fields } from 'prometheus_exporter.proc';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'conntrack',
	title: 'Connection tracking',
	help: 'The size and statistics of the connection tracking table, from /proc/sys/net/netfilter and /proc/net/stat/nf_conntrack.',
	needs: [ 'fs' ],
};

const GAUGES = [
	[ '/proc/sys/net/netfilter/nf_conntrack_count', 'node_nf_conntrack_entries',
		'Number of currently allocated flow entries for connection tracking.' ],
	[ '/proc/sys/net/netfilter/nf_conntrack_max', 'node_nf_conntrack_entries_limit',
		'Maximum size of connection tracking table.' ],
];

export const STAT = '/proc/net/stat/nf_conntrack';

// node_exporter's statistics: a column of /proc/net/stat/nf_conntrack each,
// summed over the CPUs. Gauges, as node_exporter has them, though they only
// grow: they are its names, so they keep its type.
export const STATS = [
	[ 'found', 'Number of searched entries which were successful.' ],
	[ 'invalid', 'Number of packets seen which can not be tracked.' ],
	[ 'ignore', 'Number of packets seen which are already connected to a conntrack entry.' ],
	[ 'insert', 'Number of entries inserted into the list.' ],
	[ 'insert_failed', 'Number of entries for which list insertion was attempted but failed.' ],
	[ 'drop', 'Number of packets dropped due to conntrack failure.' ],
	[ 'early_drop', 'Number of dropped conntrack entries to make room for new ones, if maximum table size was reached.' ],
	[ 'search_restart', 'Number of conntrack table lookups which had to be restarted due to hashtable resizes.' ],
];

const HEX = /^[0-9a-fA-F]+$/;

// { column: sum } of the file's hex table: a header line naming the columns,
// then a row per CPU (ct_cpu_seq_show() in the kernel's
// net/netfilter/nf_conntrack_standalone.c). The header is read rather than the
// positions procfs assumes, though they agree today: the kernel has renamed
// columns before (searched is clashres now). A string says what is wrong.
export function sum_columns(text) {
	let rows = filter(split(text, '\n'), (l) => trim(l) != '');
	let header = fields(rows[0]);

	if (!length(header))
		return 'no header';
	if (length(rows) < 2)
		return 'no rows';

	let sums = {};
	for (let name in header)
		sums[name] = 0;

	for (let i = 1; i < length(rows); i++) {
		let row = fields(rows[i]);

		if (length(row) != length(header))
			return `row ${i}: ${length(row)} columns for ${length(header)}`;

		for (let j, name in header) {
			if (!match(row[j], HEX))
				return `row ${i}: ${sprintf('%J', row[j])} is not hex`;
			sums[name] += hex(row[j]);
		}
	}

	return sums;
};

// Neither sysctl is there until nf_conntrack is loaded, as on an AP without a
// firewall. A base collector runs on every device, so a device without
// connection tracking succeeds with nothing to say, as the earlier ucode
// exporter did; one file without the other is an error. The statistics file
// is there with them unless the kernel lacks CONFIG_NF_CONNTRACK_PROCFS, so
// without it the statistics are left out; a column the kernel does not write
// leaves out its statistic.
export function collect(deps, out) {
	if (!length(filter(GAUGES, (g) => deps.fs.readfile(g[0]) != null)))
		return Result.ok();

	for (let g in GAUGES) {
		let line = first_line(deps.fs, g[0]);

		if (line == null)
			return Result.err(errors.SOURCE_UNREADABLE, g[0]);

		let v = trim(line);
		if (!match(v, COUNT))
			return Result.err(errors.SOURCE_INVALID, `${g[0]}: ${sprintf('%J', line)}`);

		out.gauge(g[1], g[2])(null, v);
	}

	let text = deps.fs.readfile(STAT);
	if (text == null)
		return Result.ok();

	let sums = sum_columns(text);
	if (type(sums) == 'string')
		return Result.err(errors.SOURCE_INVALID, `${STAT}: ${sums}`);

	for (let s in STATS)
		if (s[0] in sums)
			out.gauge(`node_nf_conntrack_stat_${s[0]}`, s[1])(null, sums[s[0]]);

	return Result.ok();
};
