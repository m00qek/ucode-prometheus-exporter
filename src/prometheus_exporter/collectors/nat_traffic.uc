'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/nat_traffic.uc and
// utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/nat_traffic.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Bytes in the conntrack table per source and destination address, as the Lua
// exporter's nat_traffic collector: for each connection, its first src= and
// dst= (the original direction) and the sum of every bytes= field (both
// directions). Without conntrack accounting (net.netfilter.nf_conntrack_acct)
// there are no bytes= fields and every pair sums to 0.
//
// The kernel writes an IPv6 address in full (%pI6: 2001:0db8:0000:...); the
// labels have it as every other collector and tool does (RFC 5952,
// 2001:db8::1), so they join with theirs.

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'nat_traffic',
	title: 'Traffic per address pair',
	help: 'Bytes per source and destination address, from /proc/net/nf_conntrack.',
	needs: [ 'fs' ],
	// The connection table, which on a busy router holds tens of thousands:
	// a 500-MIPS router takes seconds over 20,000 of them. Before the ledger
	// times it, it runs after the others, so that a first scrape after a
	// restart does not spend their time on it.
	cost: 'heavy',
	// A sample for each pair of addresses in the table, of which there are
	// at most as many as connections: OpenWrt keeps 16,384 by default
	// (net.netfilter.nf_conntrack_max), and a busy router is given 65,536.
	max_samples: 65536,
};

const CONNTRACK = '/proc/net/nf_conntrack';

// { src: { dst: bytes } } of the table, in the order the pairs first appear,
// or null when it cannot be read.
//
// The table can hold tens of thousands of entries, and each operation of
// ucode's VM costs about a microsecond on a router's CPU: a line is taken
// apart with index() and split() on fixed strings, with no regex (musl's
// regexec costs several), no array of its fields and no call of a function
// per line. The kernel separates the fields with one space (ct_seq_show() in
// net/netfilter/nf_conntrack_standalone.c); padded with one at each end, a
// field that starts with `src=` is the text after ' src=' up to the next
// space. With accounting on, a line has two bytes= (both directions): the
// parts of a split on ' bytes=' after the first, each a number up to its next
// space, or all of it where another bytes= follows at once.
function read(fs) {
	let f = fs.open(CONNTRACK, 'r');

	if (!f)
		return null;

	let totals = {};
	let line;

	while (length(line = f.read('line'))) {
		let l = ' ' + trim(line) + ' ';
		let i = index(l, ' src='), j = index(l, ' dst=');

		if (i < 0 || j < 0)
			continue;

		let src = substr(l, i + 5), dst = substr(l, j + 5);
		let parts = split(l, ' bytes=');
		let n = length(parts);
		let bytes = 0;

		// Two, as with accounting, without a loop: a fifth of a line's cost.
		if (n == 3) {
			let p = parts[1], q = parts[2], e = index(p, ' '), f = index(q, ' ');
			bytes = (+(e < 0 ? p : substr(p, 0, e)) || 0) + (+(f < 0 ? q : substr(q, 0, f)) || 0);
		} else {
			for (let k = 1; k < n; k++) {
				let p = parts[k], e = index(p, ' ');
				bytes += +(e < 0 ? p : substr(p, 0, e)) || 0;
			}
		}

		src = substr(src, 0, index(src, ' '));
		dst = substr(dst, 0, index(dst, ' '));

		let dsts = totals[src] ??= {};
		dsts[dst] = (dsts[dst] ?? 0) + bytes;
	}

	f.close();
	return totals;
}

// A pair's labels as the format writes them, as out.labels() would: written
// at once, and escaped (by out.labels()) only when the text holds a backslash
// or more quotes than its own. An address is a field of a line, so it holds
// no newline. A table of tens of thousands of pairs is that many label sets.
function pair_labels(out, src, dst) {
	let text = `{src="${src}",dst="${dst}"}`;

	return (index(text, '\\') < 0 && length(split(text, '"')) == 5) ? text : out.labels({ src, dst });
}

// An IPv6 address as the labels have it, compressed: once each.
function address(seen, a) {
	return seen[a] ??= (arrtoip(iptoarr(a)) ?? a);
}

// The labels are src and dst, as the ucode exporter's nat_traffic has them
// (the Lua one's are src and dest). /proc/net/nf_conntrack is there only
// while nf_conntrack is loaded: an access point without a firewall has none,
// which is nothing to observe, not a failure. A table that is there but
// cannot be read is one.
export function collect(deps, out) {
	let totals = read(deps.fs);

	if (totals == null)
		return deps.fs.stat(CONNTRACK) == null
			? Result.none('no connection tracking (nf_conntrack is not loaded)')
			: Result.err(errors.SOURCE_UNREADABLE, CONNTRACK);

	let traffic = out.gauge('node_nat_traffic_bytes', 'Bytes of the connections from src to dst, both directions.');
	let seen = {};

	// A connection's addresses are of one family: the destinations of an IPv4
	// source, most of a table, are taken as they are, without a call each.
	for (let src, dsts in totals) {
		if (index(src, ':') < 0) {
			for (let dst, bytes in dsts)
				traffic(pair_labels(out, src, dst), bytes);
			continue;
		}

		src = address(seen, src);
		for (let dst, bytes in dsts)
			traffic(pair_labels(out, src, address(seen, dst)), bytes);
	}

	return Result.ok();
};
