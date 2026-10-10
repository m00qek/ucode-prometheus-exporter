'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

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

export function sum_columns(text) {
	let rows = filter(split(text, '\n'), (l) => trim(l) != '');
	let header = proc.fields(rows[0]);

	if (!length(header))
		return 'no header';
	if (length(rows) < 2)
		return 'no rows';

	let sums = {};
	for (let name in header)
		sums[name] = 0;

	for (let i = 1; i < length(rows); i++) {
		let row = proc.fields(rows[i]);

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

export function collect(deps, out) {
	if (!length(filter(GAUGES, (g) => deps.fs.readfile(g[0]) != null)))
		return Result.none('no connection tracking (nf_conntrack is not loaded)');

	for (let g in GAUGES) {
		let line = proc.first_line(deps.fs, g[0]);

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
