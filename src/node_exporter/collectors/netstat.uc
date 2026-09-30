'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/netstat.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The kernel's protocol statistics, as upstream's netstat collector: each
// section of /proc/net/netstat and /proc/net/snmp is a header line of names
// and a line of values, both starting with the section ("TcpExt:"), and each
// value is a gauge node_netstat_<section>_<name>.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'netstat',
	help: 'Protocol statistics from /proc/net/netstat and /proc/net/snmp.',
	needs: [ 'fs' ],
};

const SOURCES = [ '/proc/net/netstat', '/proc/net/snmp' ];

// The sections of one file, recorded; the sections whose two lines do not
// match (named apart, or with more names than values or fewer), which are
// left out. Null when the file cannot be read.
function parse(fs, out, path) {
	let l = lines(fs, path);

	if (l == null)
		return null;

	let bad = [];

	for (let i = 0; i + 1 < length(l); i += 2) {
		let names = fields(l[i]);
		let values = fields(l[i + 1]);

		if (!length(names) || names[0] != values[0] || length(names) != length(values)
		    || substr(names[0], -1) != ':') {
			push(bad, names[0] ?? '');
			continue;
		}

		let section = substr(names[0], 0, -1);
		for (let j = 1; j < length(names); j++)
			out.gauge(`node_netstat_${section}_${names[j]}`, `${section} ${names[j]} from ${path}.`)(null, values[j]);
	}

	if (length(l) % 2)
		push(bad, fields(l[-1])[0] ?? '');

	return bad;
}

export function collect(deps, out) {
	let readable = 0;
	let invalid = [];

	for (let path in SOURCES) {
		let bad = parse(deps.fs, out, path);

		if (bad == null)
			continue;

		readable++;
		if (length(bad))
			push(invalid, `${path}: ${join(' ', bad)}`);
	}

	// Either file alone is worth exporting, as upstream has it.
	if (!readable)
		return Result.err(errors.SOURCE_UNREADABLE, join(', ', SOURCES));
	if (length(invalid))
		return Result.err(errors.SOURCE_INVALID, join('; ', invalid));

	return Result.ok();
};
