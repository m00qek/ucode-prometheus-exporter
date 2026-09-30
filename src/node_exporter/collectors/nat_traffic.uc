'use strict';

// Bytes in the conntrack table per source and destination address, as the Lua
// exporter's nat_traffic collector: for each connection, its first src= and
// dst= (the original direction) and the sum of every bytes= field (both
// directions). Without conntrack accounting (net.netfilter.nf_conntrack_acct)
// there are no bytes= fields and every pair sums to 0.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { each_line, fields } from 'node_exporter.proc';

export const meta = {
	name: 'nat_traffic',
	help: 'Bytes per source and destination address, from /proc/net/nf_conntrack.',
	needs: [ 'fs' ],
};

const CONNTRACK = '/proc/net/nf_conntrack';

// { src, dest, bytes } of one conntrack entry.
function entry(line) {
	let e = { src: null, dest: null, bytes: 0 };

	for (let f in fields(line)) {
		let m = match(f, /^(src|dst|bytes)=(.*)$/);

		if (!m)
			continue;

		if (m[1] == 'bytes')
			e.bytes += +m[2] || 0;
		else if (m[1] == 'src')
			e.src ??= m[2];
		else
			e.dest ??= m[2];
	}

	return e;
}

export function collect(deps, out) {
	// Keyed by src, then dest, in the order the pairs first appear.
	let totals = {};

	let readable = each_line(deps.fs, CONNTRACK, function(line) {
		let e = entry(line);

		if (e.src == null || e.dest == null)
			return;

		totals[e.src] ??= {};
		totals[e.src][e.dest] = (totals[e.src][e.dest] ?? 0) + e.bytes;
	});

	if (!readable)
		return Result.err(errors.SOURCE_UNREADABLE, CONNTRACK);

	let traffic = out.gauge('node_nat_traffic', 'Bytes of the connections from src to dest, both directions.');
	for (let src, dests in totals)
		for (let dest, bytes in dests)
			traffic({ src, dest }, bytes);

	return Result.ok();
};
