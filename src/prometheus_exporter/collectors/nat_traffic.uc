'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/nat_traffic.uc and
// utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/nat_traffic.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Bytes in the conntrack table per source and destination address, as the Lua
// exporter's nat_traffic collector: for each connection, its first src= and
// dst= (the original direction) and the sum of every bytes= field (both
// directions). Without conntrack accounting (net.netfilter.nf_conntrack_acct)
// there are no bytes= fields and every pair sums to 0.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { each_line } from 'prometheus_exporter.proc';

export const meta = {
	name: 'nat_traffic',
	title: 'Traffic per address pair',
	help: 'Bytes per source and destination address, from /proc/net/nf_conntrack.',
	needs: [ 'fs' ],
};

const CONNTRACK = '/proc/net/nf_conntrack';

// [ src, dst, bytes ] of one conntrack entry, or null without both addresses.
//
// The table can hold tens of thousands of entries, so a line is taken apart
// with index() and split() on fixed strings, with no regex and no array of
// its fields: musl's regexec costs microseconds a call, and a line has about
// twenty fields. The kernel separates the fields with one space
// (ct_seq_show() in net/netfilter/nf_conntrack_standalone.c); padded with one
// at each end, a field that starts with `src=` is the text after ' src='
// up to the next space.
function entry(line) {
	let l = ' ' + trim(line) + ' ';
	let i = index(l, ' src='), j = index(l, ' dst=');

	if (i < 0 || j < 0)
		return null;

	let src = substr(l, i + 5), dst = substr(l, j + 5);
	let parts = split(l, ' bytes=');
	let bytes = 0;

	for (let k = 1; k < length(parts); k++)
		bytes += +substr(parts[k], 0, index(parts[k], ' ')) || 0;

	return [ substr(src, 0, index(src, ' ')), substr(dst, 0, index(dst, ' ')), bytes ];
}

// The labels are src and dst, as the ucode exporter's nat_traffic has them
// (the Lua one's are src and dest). /proc/net/nf_conntrack is there only
// while nf_conntrack is loaded: an access point without a firewall has none,
// which is nothing to report, not a failure. A table that is there but
// cannot be read is one.
export function collect(deps, out) {
	// Keyed by src, then dst, in the order the pairs first appear.
	let totals = {};

	let readable = each_line(deps.fs, CONNTRACK, function(line) {
		let e = entry(line);

		if (e) {
			let dsts = totals[e[0]] ??= {};
			dsts[e[1]] = (dsts[e[1]] ?? 0) + e[2];
		}
	});

	if (!readable)
		return deps.fs.stat(CONNTRACK) == null ? Result.ok() : Result.err(errors.SOURCE_UNREADABLE, CONNTRACK);

	let traffic = out.gauge('node_nat_traffic_bytes', 'Bytes of the connections from src to dst, both directions.');
	for (let src, dsts in totals)
		for (let dst, bytes in dsts)
			traffic({ src, dst }, bytes);

	return Result.ok();
};
