'use strict';

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'nat_traffic',
	title: 'Traffic per address pair',
	help: 'Bytes per source and destination address, from /proc/net/nf_conntrack.',
	needs: [ 'fs' ],
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

function address(seen, a) {
	return seen[a] ??= (arrtoip(iptoarr(a)) ?? a);
}

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

	let labels = { host: null, peer: null };

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
