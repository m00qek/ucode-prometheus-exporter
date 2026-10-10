'use strict';

import { Result, errors } from 'prometheus.exporter';

export const meta = {
	name: 'nat_traffic',
	title: 'Traffic per host',
	help: 'Bytes per host on this side of the router, from /proc/net/nf_conntrack and the routes.',
	needs: [ 'fs', 'rtnl', 'log' ],
	proc_files: [ '/proc/net/nf_conntrack' ],
	cost: 'heavy',
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

export const OTHER = 'other';
export const MAX_HOSTS = 2048;
export const MAX_PAIRS = 16384;

function prefix(dst) {
	let s = index(dst, '/');
	let a = iptoarr((s < 0) ? dst : substr(dst, 0, s));

	return (a == null) ? null : [ a, (s < 0) ? length(a) * 8 : +substr(dst, s + 1) ];
}

function hops(r) {
	let devs = (r.oif != null) ? [ r.oif ] : [];

	for (let h in r.multipath ?? [])
		push(devs, h.oif ?? h.dev);

	return devs;
}

export function local_prefixes(routes, c) {
	let upstream = {};
	let prefixes = [];

	for (let r in routes)
		if (r.type == c.RTN_UNICAST && (r.dst == null || substr(r.dst, -2) == '/0'))
			for (let dev in hops(r))
				upstream[dev] = true;

	for (let r in routes) {
		if (r.dst == null)
			continue;

		let lan = r.type == c.RTN_UNICAST && r.gateway == null && r.multipath == null &&
			r.oif != null && r.oif != 'lo' && !upstream[r.oif];
		let p = (lan || r.type == c.RTN_LOCAL) ? prefix(r.dst) : null;

		if (p != null && p[1] > 0)
			push(prefixes, p);
	}

	return prefixes;
};

function within(a, p) {
	let b = p[0], len = p[1];

	if (length(a) != length(b))
		return false;

	let n = len >> 3;

	for (let i = 0; i < n; i++)
		if (a[i] != b[i])
			return false;

	let r = len & 7;

	return r == 0 || ((a[n] ^ b[n]) & (0xff << (8 - r)) & 0xff) == 0;
}

export function is_local(prefixes, addr) {
	let a = iptoarr(addr);

	if (a == null)
		return false;

	for (let p in prefixes)
		if (within(a, p))
			return true;

	return false;
};

function read(f, peers, prefixes) {
	let totals = {};
	let known = {};
	let line;

	function local(addr) {
		return known[addr] ??= is_local(prefixes, addr);
	}

	while (length(line = f.read('line'))) {
		let l = ' ' + trim(line) + ' ';
		let i = index(l, ' src='), j = index(l, ' dst=');

		if (i < 0 || j < 0)
			continue;

		let src = substr(l, i + 5), dst = substr(l, j + 5);
		let parts = split(l, ' bytes=');
		let n = length(parts);
		let bytes = 0;

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
		let s = substr(src, 0, index(src, ' ')), d = substr(dst, 0, index(dst, ' '));
		let host, peer;
		let reply = null;

		if (r >= 0) {
			reply = substr(dst, r + 5);
			reply = substr(reply, 0, index(reply, ' '));
		}

		if (reply != null && reply != d && local(reply)) {
			host = reply;
			peer = s;
		} else if (known[s] ?? local(s)) {
			host = s;
			peer = d;
		} else if (known[d] ?? local(d)) {
			host = d;
			peer = s;
		} else {
			host = OTHER;
			peer = OTHER;
		}

		if (peers) {
			let of = totals[host] ??= {};
			of[peer] = (of[peer] ?? 0) + bytes;
		} else
			totals[host] = (totals[host] ?? 0) + bytes;
	}

	return totals;
}

function sum(of) {
	if (type(of) != 'object')
		return of;

	let n = 0;

	for (let k, b in of)
		n += b;

	return n;
}

function largest(rows, max) {
	let kept = {};

	sort(rows, (x, y) => (y[1] - x[1]) || ((x[0] < y[0]) ? -1 : (x[0] > y[0]) ? 1 : 0));
	for (let i = 0; i < max && i < length(rows); i++)
		kept[rows[i][0]] = true;

	return kept;
}

function cap_hosts(totals, peers, log) {
	let rows = [];

	for (let host, of in totals)
		if (host != OTHER)
			push(rows, [ host, sum(of) ]);

	if (length(rows) <= MAX_HOSTS)
		return totals;

	let kept = largest(rows, MAX_HOSTS);
	let capped = {};
	let rest = 0;

	for (let host, of in totals) {
		if (kept[host])
			capped[host] = of;
		else
			rest += sum(of);
	}

	capped[OTHER] = peers ? { [OTHER]: rest } : rest;

	log(`${length(rows) - MAX_HOSTS} hosts past the ${MAX_HOSTS} it writes, written as host "${OTHER}"`);
	return capped;
}

function cap_pairs(totals, log) {
	let rows = [];

	for (let host, of in totals)
		for (let peer, b in of)
			push(rows, [ host + ' ' + peer, b ]);

	if (length(rows) <= MAX_PAIRS)
		return totals;

	let kept = largest(rows, MAX_PAIRS);
	let capped = {};

	for (let host, of in totals) {
		let to = capped[host] = {};
		let rest = null;

		for (let peer, b in of) {
			if (kept[host + ' ' + peer])
				to[peer] = b;
			else
				rest = (rest ?? 0) + b;
		}

		if (rest != null)
			to[OTHER] = (to[OTHER] ?? 0) + rest;
	}

	log(`${length(rows) - MAX_PAIRS} pairs past the ${MAX_PAIRS} it writes, written as peer "${OTHER}" of their hosts`);
	return capped;
}

function address(seen, a) {
	return seen[a] ??= (arrtoip(iptoarr(a)) ?? a);
}

export function collect(deps, out, options) {
	let peers = options.peers;
	let f = deps.fs.open(CONNTRACK, 'r');

	if (!f)
		return deps.fs.stat(CONNTRACK) == null
			? Result.none('no connection tracking (nf_conntrack is not loaded)')
			: Result.err(errors.SOURCE_UNREADABLE, CONNTRACK);

	let c = deps.rtnl.const;
	let routes = deps.rtnl.request(c.RTM_GETROUTE, c.NLM_F_DUMP);

	if (!routes.ok) {
		f.close();
		return routes;
	}

	let totals = read(f, peers, local_prefixes(routes.data ?? [], c));

	f.close();
	totals = cap_hosts(totals, peers, deps.log);
	if (peers)
		totals = cap_pairs(totals, deps.log);

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

	let labels = { host: null, peer: null };

	for (let host, of in totals) {
		if (index(host, ':') < 0) {
			labels.host = host;
			for (let peer, bytes in of) {
				labels.peer = (index(peer, ':') < 0) ? peer : address(seen, peer);
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
