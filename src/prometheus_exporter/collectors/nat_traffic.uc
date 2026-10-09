'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/nat_traffic.uc and
// utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/nat_traffic.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Bytes in the conntrack table per host on this side of the router, from the
// Lua exporter's nat_traffic collector: for each connection, the sum of every
// bytes= field (both directions), added to the host's. Without conntrack
// accounting (net.netfilter.nf_conntrack_acct) there are no bytes= fields and
// every host sums to 0.
//
// A connection's host is its original direction's source (its first src=),
// the address that opened it: a LAN client, or the router itself. Unless the
// connection is destination-NATed, as a port forward's are: there the reply
// comes from another address than the one the source asked for (the second
// src=, the reply direction's, is not the first dst=), and that address, the
// LAN host the router forwarded it to, is the host. So the series are as many
// as the hosts that open connections or are forwarded them, which a LAN
// bounds, whatever the peers they talk to. A connection opened from outside
// to the router itself (a WireGuard or SSH server on its WAN) is still its
// peer's: the conntrack table cannot tell it from a LAN host's. One a rule
// redirects to the router (DNS caught on its way out) is the router's.
//
// The `peers` option, off by default, labels each host's bytes by the address
// at the other end too (the first dst=, or for a forwarded connection the
// first src=): a series per host and peer, which comes with the first
// connection between them and goes with the last. On a busy router those are
// thousands, a new set every few minutes: Prometheus keeps each series it has
// seen in its head block for hours, so their number grows far past the
// table's. It is for a short look at who talks to whom, not for every scrape.
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
	// The table is r--r----- root:root: the service gives its group read access.
	proc_files: [ '/proc/net/nf_conntrack' ],
	// The connection table, which on a busy router holds tens of thousands:
	// a 500-MIPS router takes seconds over 20,000 of them. Before the ledger
	// times it, it runs after the others, so that a first scrape after a
	// restart does not spend their time on it.
	cost: 'heavy',
	// A sample for each host, or with `peers` for each pair of addresses in
	// the table, of which there are at most as many as connections: OpenWrt
	// keeps 16,384 by default (net.netfilter.nf_conntrack_max), and a busy
	// router is given 65,536.
	max_samples: 65536,
	options: {
		peers: {
			default: false,
			title: 'Series per peer',
			help: 'Label each host\'s bytes by the address at the other end too: a series per host and peer, as many as the connections and new with each, which a Prometheus server keeps for hours.',
		},
	},
};

const CONNTRACK = '/proc/net/nf_conntrack';

// { host: bytes } of the table, or with `peers` { host: { peer: bytes } }, in
// the order they first appear; null when it cannot be read.
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
// space, or all of it where another bytes= follows at once. The reply's src=
// is the first after the original dst=.
function read(fs, peers) {
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

		let r = index(dst, ' src=');
		let host = substr(src, 0, index(src, ' ')), peer = substr(dst, 0, index(dst, ' '));

		// Forwarded: the reply's source, not the one asked, is the host.
		if (r >= 0) {
			let reply = substr(dst, r + 5);

			reply = substr(reply, 0, index(reply, ' '));
			if (reply != peer) {
				peer = host;
				host = reply;
			}
		}

		if (peers) {
			let of = totals[host] ??= {};
			of[peer] = (of[peer] ?? 0) + bytes;
		} else
			totals[host] = (totals[host] ?? 0) + bytes;
	}

	f.close();
	return totals;
}

// An IPv6 address as the labels have it, compressed: once each.
function address(seen, a) {
	return seen[a] ??= (arrtoip(iptoarr(a)) ?? a);
}

// /proc/net/nf_conntrack is there only while nf_conntrack is loaded: an
// access point without a firewall has none, which is nothing to observe, not
// a failure. A table that is there but cannot be read is one.
export function collect(deps, out, options) {
	let peers = options.peers;
	let totals = read(deps.fs, peers);

	if (totals == null)
		return deps.fs.stat(CONNTRACK) == null
			? Result.none('no connection tracking (nf_conntrack is not loaded)')
			: Result.err(errors.SOURCE_UNREADABLE, CONNTRACK);

	let traffic = out.gauge('node_nat_traffic_bytes', 'Bytes of the connections of a host on this side of the router, both directions.');
	let seen = {};

	if (!peers) {
		let labels = { host: null };

		for (let host, bytes in totals) {
			labels.host = (index(host, ':') < 0) ? host : address(seen, host);
			traffic(labels, bytes);
		}

		return Result.ok();
	}

	// One object for every sample's labels, its peer set for each: the
	// recorder writes them as it takes the sample, and keeps nothing of the
	// object, so none is made for each of tens of thousands.
	let labels = { host: null, peer: null };

	// A connection's addresses are of one family: the peers of an IPv4 host,
	// most of a table, are taken as they are, without a call each.
	for (let host, of in totals) {
		if (index(host, ':') < 0) {
			labels.host = host;
			for (let peer, bytes in of) {
				labels.peer = peer;
				traffic(labels, bytes);
			}
			continue;
		}

		labels.host = address(seen, host);
		for (let peer, bytes in of) {
			labels.peer = address(seen, peer);
			traffic(labels, bytes);
		}
	}

	return Result.ok();
};
