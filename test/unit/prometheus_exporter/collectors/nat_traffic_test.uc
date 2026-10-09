'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus_exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as nat_traffic from 'prometheus_exporter.collectors.nat_traffic';

// The caju router's conntrack table, public addresses mapped to documentation
// ranges (its CGNAT WAN address to 100.64.0.1).
const CONNTRACK = fixtures.file('caju-router', '/proc/net/nf_conntrack');

// A series per peer too.
const PEERS = { peers: '1' };

function head(text, n) {
	return join('\n', slice(split(text, '\n'), 0, n)) + '\n';
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function total(lines) {
	let sum = 0;

	for (let l in samples(lines))
		sum += +split(l, ' ')[1];

	return sum;
}

function with_table(text, cb, options) {
	with_collector(nat_traffic, { fs: { data: { '/proc/net/nf_conntrack': text } }, options }, cb);
}

// A conntrack entry as the kernel writes it, with accounting on: a LAN host's
// connection out, masqueraded.
function entry(src, dst, out_bytes, in_bytes) {
	return `ipv4     2 tcp      6 7428 ESTABLISHED src=${src} dst=${dst} sport=55465 dport=443 ` +
		`packets=1 bytes=${out_bytes} src=${dst} dst=100.64.0.1 sport=443 dport=55465 ` +
		`packets=1 bytes=${in_bytes} [ASSURED] mark=0 zone=0 use=2\n`;
}

// A connection from `remote` to the router's WAN address, port forwarded to
// LAN host `lan`: the reply comes from `lan`.
function forwarded(remote, lan, out_bytes, in_bytes) {
	return `ipv4     2 tcp      6 7428 ESTABLISHED src=${remote} dst=100.64.0.1 sport=51000 dport=8443 ` +
		`packets=1 bytes=${out_bytes} src=${lan} dst=${remote} sport=443 dport=51000 ` +
		`packets=1 bytes=${in_bytes} [ASSURED] mark=0 zone=0 use=2\n`;
}

describe('collectors.nat_traffic', () => {
	it('sums both directions per host, in the order the hosts appear', () => {
		with_table(head(CONNTRACK, 12), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_nat_traffic_bytes Bytes of the connections of a host on this side of the router, both directions.',
				'# TYPE node_nat_traffic_bytes gauge',
				'node_nat_traffic_bytes{host="10.193.13.193"} 58145961',
				'node_nat_traffic_bytes{host="10.193.13.116"} 109128',
				'node_nat_traffic_bytes{host="10.193.13.100"} 43626',
				// Two SSH connections, 4974 + 6018 and 6814 + 25266 bytes.
				'node_nat_traffic_bytes{host="10.251.223.1"} 43072',
				'node_nat_traffic_bytes{host="10.193.17.70"} 9133',
			], r.lines);
		});
	});

	it('sums both directions per host and peer with peers, in the order the pairs appear', () => {
		with_table(head(CONNTRACK, 12), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_nat_traffic_bytes Bytes of the connections of a host on this side of the router, both directions.',
				'# TYPE node_nat_traffic_bytes gauge',
				'node_nat_traffic_bytes{host="10.193.13.193",peer="192.0.2.1"} 534196',
				'node_nat_traffic_bytes{host="10.193.13.193",peer="192.0.2.3"} 65061',
				'node_nat_traffic_bytes{host="10.193.13.193",peer="192.0.2.5"} 57450692',
				'node_nat_traffic_bytes{host="10.193.13.193",peer="192.0.2.6"} 15606',
				'node_nat_traffic_bytes{host="10.193.13.193",peer="192.0.2.8"} 80406',
				'node_nat_traffic_bytes{host="10.193.13.116",peer="192.0.2.2"} 52647',
				'node_nat_traffic_bytes{host="10.193.13.116",peer="192.0.2.7"} 9989',
				'node_nat_traffic_bytes{host="10.193.13.116",peer="192.0.2.9"} 46492',
				'node_nat_traffic_bytes{host="10.193.13.100",peer="192.0.2.4"} 43626',
				'node_nat_traffic_bytes{host="10.251.223.1",peer="10.193.11.1"} 43072',
				'node_nat_traffic_bytes{host="10.193.17.70",peer="192.0.2.10"} 9133',
			], r.lines);
		}, PEERS);
	});

	it('accounts for every byte of the whole caju router table, IPv6 too, in a series per host', () => {
		with_table(CONNTRACK, (r) => {
			assert.match(true, r.result.ok);
			assert.match(14, length(samples(r.lines)));
			assert.match(242156839, total(r.lines));
			assert.match(contains([
				'node_nat_traffic_bytes{host="2001:db8:0:1::e157"} 77100',
			]), r.lines);
		});
	});

	it('accounts for every byte of the whole caju router table with peers, in a series per pair', () => {
		with_table(CONNTRACK, (r) => {
			assert.match(true, r.result.ok);
			assert.match(75, length(samples(r.lines)));
			assert.match(242156839, total(r.lines));
			assert.match(contains([
				'node_nat_traffic_bytes{host="2001:db8:0:1::e157",peer="2001:db8:0:2::1"} 77100',
			]), r.lines);
		}, PEERS);
	});

	it("counts a port-forwarded connection as the LAN host's it reaches, the remote address its peer", () => {
		let table = forwarded('198.51.100.7', '10.0.0.5', 1, 2) + forwarded('203.0.113.9', '10.0.0.5', 3, 4) + entry('10.0.0.5', '192.0.2.1', 5, 6);

		with_table(table, (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.5"} 21' ], samples(r.lines));
		});
		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="10.0.0.5",peer="198.51.100.7"} 3',
				'node_nat_traffic_bytes{host="10.0.0.5",peer="203.0.113.9"} 7',
				'node_nat_traffic_bytes{host="10.0.0.5",peer="192.0.2.1"} 11',
			], samples(r.lines));
		}, PEERS);
	});

	it("counts a connection a rule redirects to the router as the router's", () => {
		let redirected = 'ipv4     2 udp      17 29 src=10.0.0.2 dst=192.0.2.53 sport=5353 dport=53 packets=1 bytes=60 ' +
			'src=10.0.0.1 dst=10.0.0.2 sport=53 dport=5353 packets=1 bytes=120 mark=0 zone=0 use=2\n';

		with_table(redirected, (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.1"} 180' ], samples(r.lines));
		});
	});

	// The kernel writes them in full; every other collector and tool, compressed.
	it('labels an IPv6 address compressed, as RFC 5952 writes it, and an IPv4 one as it is', () => {
		let table = replace(entry('2001:0db8:0000:0000:0000:0000:0000:0001', 'fe80:0000:0000:0000:0211:22ff:fe33:4455', 1, 2), 'ipv4     2', 'ipv6     10') +
			replace(entry('2001:0db8:0000:0000:0000:0000:0000:0001', '2001:0db8:0000:0000:0000:0000:0000:0002', 3, 4), 'ipv4     2', 'ipv6     10') +
			entry('10.0.0.2', '192.0.2.1', 5, 6);

		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="2001:db8::1",peer="fe80::211:22ff:fe33:4455"} 3',
				'node_nat_traffic_bytes{host="2001:db8::1",peer="2001:db8::2"} 7',
				'node_nat_traffic_bytes{host="10.0.0.2",peer="192.0.2.1"} 11',
			], samples(r.lines));
		}, PEERS);
		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="2001:db8::1"} 10',
				'node_nat_traffic_bytes{host="10.0.0.2"} 11',
			], samples(r.lines));
		});
	});

	it('gives 0 for connections without accounting', () => {
		with_table('ipv4     2 udp      17 29 src=10.0.0.2 dst=198.51.100.7 sport=5353 dport=5353 [UNREPLIED] ' +
				'src=198.51.100.7 dst=10.0.0.2 sport=5353 dport=5353 mark=0 zone=0 use=2\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.2"} 0' ], samples(r.lines));
		});
	});

	it('skips lines without both addresses', () => {
		with_table('garbage\n' + entry('10.0.0.2', '192.0.2.1', 1, 2) + 'ipv4 2 tcp 6 1 src=10.0.0.3 bytes=9\n', (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.2"} 3' ], samples(r.lines));
		});
	});

	// Addresses as a table could hold them, if not as the kernel writes them:
	// the labels are still escaped, and a third bytes= still counts.
	it('escapes what an address would need escaped, and sums every bytes=', () => {
		with_table('ipv4 2 tcp 6 1 src=a"b dst=c\\d bytes=1 bytes=2 bytes=3\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="a\\"b",peer="c\\\\d"} 6' ], samples(r.lines));
		}, PEERS);
	});

	// The collector reads a line with index() and split() for speed; on any
	// line whose fields are separated by spaces, as the kernel writes them, it
	// must read what splitting it into fields and matching each would: the
	// first src= and dst=, the first src= after that dst= (the reply's), and
	// every bytes=.
	const FIELD = /^(src|dst|bytes)=(.*)$/;

	function reference(text, peers) {
		let totals = {}, out = [];

		for (let line in split(text, '\n')) {
			let t = trim(line);
			let e = { src: null, dst: null, reply: null, bytes: 0 };

			for (let f in (t == '' ? [] : split(t, / +/))) {
				let m = match(f, FIELD);
				if (!m)
					continue;
				if (m[1] == 'bytes')
					e.bytes += +m[2] || 0;
				else if (m[1] == 'src') {
					if (e.dst != null)
						e.reply ??= m[2];
					e.src ??= m[2];
				}
				else
					e.dst ??= m[2];
			}

			if (e.src == null || e.dst == null)
				continue;

			let host = e.src, peer = e.dst;
			if (e.reply != null && e.reply != e.dst) {
				host = e.reply;
				peer = e.src;
			}

			totals[host] ??= {};
			totals[host][peer] = (totals[host][peer] ?? 0) + e.bytes;
		}

		function label(a) {
			return index(a, ':') < 0 ? a : (arrtoip(iptoarr(a)) ?? a);
		}

		for (let host, of in totals) {
			let sum = 0;

			for (let peer, b in of) {
				sum += b;
				if (peers)
					push(out, `node_nat_traffic_bytes{host="${label(host)}",peer="${label(peer)}"} ${b}`);
			}
			if (!peers)
				push(out, `node_nat_traffic_bytes{host="${label(host)}"} ${sum}`);
		}

		return out;
	}

	prop('reads any line of space-separated fields as matching each field would',
		gen.tuple(gen.array(gen.array(gen.tuple(
			gen.elements('src=', 'dst=', 'bytes=', 'sport=', 'xsrc=', 'ipv4', '[ASSURED]'),
			gen.elements('', '1', '22', '10.0.0.1', 'fd00::1', '7x', 'bytes=3', 'src=b')),
			{ min_len: 0, max_len: 8 }), { min_len: 0, max_len: 6 }), gen.bool()),
		(t) => {
			let text = join('', map(t[0], (fields) => join(' ', map(fields, (f) => f[0] + f[1])) + '\n'));

			with_table(text, (r) => assert.match(reference(text, t[1]), samples(r.lines), text), { peers: t[1] ? '1' : '0' });
		});

	it('exports nothing for an empty table', () => {
		with_table('', (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	// nat_traffic is in the network and full groups, which access points
	// without a firewall install too.
	it('has nothing to observe where nf_conntrack is not loaded', () => {
		with_table(null, (r) => {
			assert.match({ ok: true, none: 'no connection tracking (nf_conntrack is not loaded)', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails with SOURCE_UNREADABLE when a table that is there cannot be read', () => {
		let fs = { data: { '/proc/net/nf_conntrack': entry('10.0.0.2', '192.0.2.1', 1, 2) }, behavior: { open: () => null } };

		with_collector(nat_traffic, { fs }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/net/nf_conntrack' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	prop('the sum of each host, and of each pair with peers, is the bytes of its connections, both directions',
		gen.array(gen.tuple(gen.int(0, 2), gen.int(0, 2), gen.int(0, 100000000), gen.int(0, 100000000), gen.bool()),
			{ min_len: 0, max_len: 30 }), (conns) => {
			let text = '';
			let hosts = {}, pairs = {};

			for (let c in conns) {
				let lan = `10.0.0.${c[0]}`, remote = `192.0.2.${c[1]}`;
				let host = `node_nat_traffic_bytes{host="${lan}"}`;
				let pair = `node_nat_traffic_bytes{host="${lan}",peer="${remote}"}`;

				// Out to the remote address, or forwarded in from it.
				text += c[4] ? forwarded(remote, lan, c[2], c[3]) : entry(lan, remote, c[2], c[3]);
				hosts[host] = (hosts[host] ?? 0) + c[2] + c[3];
				pairs[pair] = (pairs[pair] ?? 0) + c[2] + c[3];
			}

			with_table(text, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(hosts), (k) => `${k} ${hosts[k]}`)), sort(samples(r.lines)));
			});
			with_table(text, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(pairs), (k) => `${k} ${pairs[k]}`)), sort(samples(r.lines)));
			}, PEERS);
		});
});
