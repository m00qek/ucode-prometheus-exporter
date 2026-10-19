'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as nat_traffic from 'prometheus.collectors.nat_traffic';
import * as exposition from 'prometheus.exporter.exposition';

// The caju router's conntrack table, public addresses mapped to documentation
// ranges (its CGNAT WAN address to 100.64.0.1).
const CONNTRACK = fixtures.file('caju-router', '/proc/net/nf_conntrack');

// Its routes, in the same addresses; see test/fixtures/SOURCES.
const CAJU_ROUTES = json(fixtures.file('caju-router', '/rtnl/RTM_GETROUTE.json'));

// A series per peer too.
const PEERS = { peers: '1' };

// What the collector takes of rtnl.const, as linux/rtnetlink.h and netlink.h
// have them: utest's shim of rtnl does not compile in a test that imports it.
function rtnl_const() {
	return { RTM_GETROUTE: 26, NLM_F_DUMP: 0x300, RTN_UNICAST: 1, RTN_LOCAL: 2 };
}

function route(dst, oif, more) {
	return { family: (dst != null && index(dst, ':') >= 0) ? 10 : 2, type: 1, table: 254, dst, oif, ...(more ?? {}) };
}

function own(addr, oif) {
	let six = index(addr, ':') >= 0;

	return { family: six ? 10 : 2, type: 2, table: 255, dst: addr + (six ? '/128' : '/32'), oif };
}

// A router as rtnl dumps its routes: the LAN 10.0.0.0/24, fd00::/64 and the
// delegated 2001:db8:1:10::/64 on br-lan, a subnet behind a LAN router; the
// WAN, eth1, with the default routes, its on-link 100.64.0.0/10 and the
// ISP's 2001:db8:ffff::/64; the delegated /56 unreachable; and its own
// addresses in the local table.
const ROUTES = [
	route(null, 'eth1', { gateway: '100.64.0.254' }),
	route(null, 'eth1', { family: 10, gateway: 'fe80::1', src: '2001:db8:1::/56' }),
	route('100.64.0.0/10', 'eth1', { scope: 253 }),
	route('2001:db8:ffff::/64', 'eth1'),
	route('10.0.0.0/24', 'br-lan', { scope: 253 }),
	route('fd00::/64', 'br-lan'),
	route('2001:db8:1:10::/64', 'br-lan'),
	route('2001:db8:1::/56', 'lo', { type: 7 }),
	route('198.51.100.0/24', 'br-lan', { gateway: '10.0.0.254' }),
	own('100.64.0.1', 'eth1'),
	own('2001:db8:ffff::2', 'eth1'),
	own('10.0.0.1', 'br-lan'),
	own('2001:db8:1:10::1', 'br-lan'),
	{ family: 2, type: 2, table: 255, dst: '127.0.0.0/8', oif: 'lo' },
	{ family: 2, type: 3, table: 255, dst: '10.0.0.255/32', oif: 'br-lan' },
];

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

function with_table(text, cb, options, routes) {
	with_collector(nat_traffic, { fs: { data: { '/proc/net/nf_conntrack': text } }, rtnl: { data: { RTM_GETROUTE: routes ?? ROUTES } }, options }, cb);
}

function with_caju(text, cb, options) {
	with_table(text, cb, options, CAJU_ROUTES);
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

// A connection neither end NATs: from `src` to `dst`, as the firewall
// accepts one from the internet to the router or to a LAN host.
function routed(family, proto, src, dst, out_bytes, in_bytes) {
	return `${family}     ${family == 'ipv4' ? 2 : 10} ${proto} 29 src=${src} dst=${dst} type=8 code=0 id=1 ` +
		`packets=1 bytes=${out_bytes} src=${dst} dst=${src} type=0 code=0 id=1 packets=1 bytes=${in_bytes} mark=0 zone=0 use=2\n`;
}

function v6(line) {
	return replace(line, 'ipv4     2', 'ipv6     10');
}

// An IPv6 address in full, as the kernel writes it.
function full(a) {
	let b = iptoarr(a), parts = [];

	for (let i = 0; i < 16; i += 2)
		push(parts, sprintf('%02x%02x', b[i], b[i + 1]));

	return join(':', parts);
}

describe('collectors.nat_traffic', () => {
	it('sums both directions per host, in the order the hosts appear', () => {
		with_caju(head(CONNTRACK, 12), (r) => {
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
		with_caju(head(CONNTRACK, 12), (r) => {
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
		with_caju(CONNTRACK, (r) => {
			assert.match(true, r.result.ok);
			assert.match(14, length(samples(r.lines)));
			assert.match(242156839, total(r.lines));
			assert.match(contains([
				'node_nat_traffic_bytes{host="2001:db8:0:1::e157"} 77100',
			]), r.lines);
		});
	});

	it('accounts for every byte of the whole caju router table with peers, in a series per pair', () => {
		with_caju(CONNTRACK, (r) => {
			assert.match(true, r.result.ok);
			assert.match(75, length(samples(r.lines)));
			assert.match(242156839, total(r.lines));
			assert.match(contains([
				'node_nat_traffic_bytes{host="2001:db8:0:1::e157",peer="2001:db8:0:2::1"} 77100',
			]), r.lines);
		}, PEERS);
	});

	it('asks rtnl for the routes of every table', () => {
		let asked = [];
		let rtnl = { behavior: { request: (cmd, flags, attrs) => { push(asked, [ cmd, flags, attrs ]); return ROUTES; } } };

		with_collector(nat_traffic, { fs: { data: { '/proc/net/nf_conntrack': entry('10.0.0.2', '192.0.2.1', 1, 2) } }, rtnl }, (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.2"} 3' ], samples(r.lines));
		});
		assert.match([ [ rtnl_const().RTM_GETROUTE, rtnl_const().NLM_F_DUMP, null ] ], asked);
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

	// The firewall accepts these from the internet without NAT: the sender
	// was the host, a series for every scanner.
	it('counts a ping to the WAN address as the router\'s, and ICMPv6 to a LAN host as that host\'s, the sender their peer', () => {
		let lan6 = full('2001:db8:1:10::5'), scanner6 = full('2001:db8:bad::7');
		let table = routed('ipv4', 'icmp     1', '198.51.100.7', '100.64.0.1', 84, 84) +
			routed('ipv4', 'icmp     1', '203.0.113.9', '100.64.0.1', 84, 84) +
			routed('ipv6', 'icmpv6   58', scanner6, lan6, 104, 104) +
			routed('ipv6', 'icmpv6   58', full('2001:db8:bad::8'), full('2001:db8:ffff::2'), 104, 104);

		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="100.64.0.1"} 336',
				'node_nat_traffic_bytes{host="2001:db8:1:10::5"} 208',
				'node_nat_traffic_bytes{host="2001:db8:ffff::2"} 208',
			], samples(r.lines));
		});
		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="100.64.0.1",peer="198.51.100.7"} 168',
				'node_nat_traffic_bytes{host="100.64.0.1",peer="203.0.113.9"} 168',
				'node_nat_traffic_bytes{host="2001:db8:1:10::5",peer="2001:db8:bad::7"} 208',
				'node_nat_traffic_bytes{host="2001:db8:ffff::2",peer="2001:db8:bad::8"} 208',
			], samples(r.lines));
		}, PEERS);
	});

	// On-link means a route without a gateway on an interface without a
	// default route: the WAN's subnets and a subnet behind a LAN router are
	// not; an address of the router's own is, on the WAN too.
	it('writes the bytes of a connection neither end of which is on this side as one series, host "other"', () => {
		let table = routed('ipv4', 'icmp     1', '198.51.100.7', '203.0.113.9', 1, 2) +
			routed('ipv4', 'icmp     1', '100.64.3.3', '100.64.4.4', 3, 4) +
			routed('ipv6', 'icmpv6   58', full('2001:db8:ffff::9'), full('2001:db8:bad::1'), 5, 6) +
			routed('ipv6', 'icmpv6   58', full('2001:db8:1:20::9'), full('2001:db8:bad::1'), 7, 8) +
			entry('10.0.0.2', '192.0.2.1', 9, 10);

		with_table(table, (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="other"} 36', 'node_nat_traffic_bytes{host="10.0.0.2"} 19' ], samples(r.lines));
		});
		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="other",peer="other"} 36',
				'node_nat_traffic_bytes{host="10.0.0.2",peer="192.0.2.1"} 19',
			], samples(r.lines));
		}, PEERS);
	});

	it('takes a port forward to a host that is not on this side for its other end', () => {
		with_table(forwarded('203.0.113.9', '198.51.100.20', 1, 2), (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="100.64.0.1",peer="203.0.113.9"} 3' ], samples(r.lines));
		}, PEERS);
	});

	// The kernel writes them in full; every other collector and tool, compressed.
	it('labels an IPv6 address compressed, as RFC 5952 writes it, and an IPv4 one as it is', () => {
		let host = full('2001:db8:1:10::1');
		let table = v6(entry(host, 'fe80:0000:0000:0000:0211:22ff:fe33:4455', 1, 2)) +
			v6(entry(host, full('2001:db8:1:10::2'), 3, 4)) +
			entry('10.0.0.2', '192.0.2.1', 5, 6);

		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="2001:db8:1:10::1",peer="fe80::211:22ff:fe33:4455"} 3',
				'node_nat_traffic_bytes{host="2001:db8:1:10::1",peer="2001:db8:1:10::2"} 7',
				'node_nat_traffic_bytes{host="10.0.0.2",peer="192.0.2.1"} 11',
			], samples(r.lines));
		}, PEERS);
		with_table(table, (r) => {
			assert.match([
				'node_nat_traffic_bytes{host="2001:db8:1:10::1"} 10',
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
		with_table('ipv4 2 tcp 6 1 src=10.0.0.2 dst=c\\d"e bytes=1 bytes=2 bytes=3\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="10.0.0.2",peer="c\\\\d\\"e"} 6' ], samples(r.lines));
		}, PEERS);
		with_table('ipv4 2 tcp 6 1 src=a"b dst=c\\d bytes=1 bytes=2 bytes=3\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{host="other",peer="other"} 6' ], samples(r.lines));
		}, PEERS);
	});

	// The collector reads a line with index() and split() for speed; on any
	// line whose fields are separated by spaces, as the kernel writes them, it
	// must read what splitting it into fields and matching each would: the
	// first src= and dst=, the first src= after that dst= (the reply's), and
	// every bytes=; and take for the host the reply's source where it is not
	// the destination and is on this side, else the source, else the
	// destination, whichever is on this side, else "other".
	const FIELD = /^(src|dst|bytes)=(.*)$/;
	const THIS_SIDE = { '10.0.0.1': true, 'fd00::1': true };

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

			let host = 'other', peer = 'other';
			if (e.reply != null && e.reply != e.dst && THIS_SIDE[e.reply]) {
				host = e.reply;
				peer = e.src;
			} else if (THIS_SIDE[e.src]) {
				host = e.src;
				peer = e.dst;
			} else if (THIS_SIDE[e.dst]) {
				host = e.dst;
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
			gen.elements('', '1', '22', '10.0.0.1', 'fd00::1', '7x', 'bytes=3', 'src=b', '192.0.2.1')),
			{ min_len: 0, max_len: 8 }), { min_len: 0, max_len: 6 }), gen.bool()),
		(t) => {
			let text = join('', map(t[0], (fields) => join(' ', map(fields, (f) => f[0] + f[1])) + '\n'));
			let routes = [ route('10.0.0.0/31', 'br-lan'), route('fd00::/127', 'br-lan'), route(null, 'eth1', { gateway: '192.0.2.254' }) ];

			with_table(text, (r) => assert.match(reference(text, t[1]), samples(r.lines), text), { peers: t[1] ? '1' : '0' }, routes);
		});

	it('exports nothing for an empty table', () => {
		with_table('', (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	// nat_traffic is in the network and full groups, which access points
	// without a firewall install too.
	it('has nothing to observe where nf_conntrack is not loaded, and asks rtnl nothing', () => {
		with_table(null, (r) => {
			assert.match({ ok: true, none: 'no connection tracking (nf_conntrack is not loaded)', error: null, lines: [], logs: [] }, outcome(r));
		}, null, () => die('asked rtnl'));
	});

	it('fails with SOURCE_UNREADABLE when a table that is there cannot be read', () => {
		let fs = { data: { '/proc/net/nf_conntrack': entry('10.0.0.2', '192.0.2.1', 1, 2) }, behavior: { open: () => null } };

		with_collector(nat_traffic, { fs, rtnl: { data: { RTM_GETROUTE: ROUTES } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/net/nf_conntrack' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with RTNL_FAILED when the routes cannot be read, writing nothing', () => {
		let fs = { data: { '/proc/net/nf_conntrack': entry('10.0.0.2', '192.0.2.1', 1, 2) } };

		with_collector(nat_traffic, { fs, rtnl: { errors: { RTM_GETROUTE: 'Operation not permitted' } } }, (r) => {
			assert.match([ false, 'RTNL_FAILED', [] ], [ r.result.ok, r.result.error, r.lines ]);
		});
	});

	// A LAN of a /16 bounds the series no more than the internet does.
	it('writes at most MAX_HOSTS hosts, the largest, and the rest as host "other", saying so', () => {
		let routes = [ route('10.0.0.0/16', 'br-lan') ];
		let rows = [];

		for (let i = 0; i < nat_traffic.MAX_HOSTS + 3; i++)
			push(rows, entry(`10.0.${i >> 8}.${i & 255}`, '192.0.2.1', i + 10, 0));

		let table = join('', rows);

		with_table(table, (r) => {
			let s = samples(r.lines);

			assert.match([ nat_traffic.MAX_HOSTS + 1, 'node_nat_traffic_bytes{host="10.0.0.3"} 13', 'node_nat_traffic_bytes{host="other"} 33' ],
				[ length(s), s[0], s[length(s) - 1] ]);
			assert.match([ `collector 'nat_traffic': 3 hosts past the ${nat_traffic.MAX_HOSTS} it writes, written as host "other"` ], r.logs);
		}, null, routes);
		with_table(table, (r) => {
			let s = samples(r.lines);

			assert.match([ nat_traffic.MAX_HOSTS + 1, 'node_nat_traffic_bytes{host="other",peer="other"} 33' ], [ length(s), s[length(s) - 1] ]);
		}, PEERS, routes);
	});

	// Run without the harness, whose file mock reads a table this large a
	// line at a time in seconds.
	it('writes at most MAX_PAIRS pairs with peers, the largest, and the rest as peer "other" of their hosts, saying so', () => {
		let rows = [];

		for (let i = 0; i < nat_traffic.MAX_PAIRS + 2; i++)
			push(rows, entry(`10.0.0.${i & 1}`, `192.0.${i >> 8}.${i & 255}`, i + 10, 0));

		let logs = [];
		let at = 0;
		let deps = {
			fs: { open: () => ({ read: () => rows[at++] ?? '', close: () => true }), stat: () => ({}) },
			rtnl: { const: rtnl_const(), request: () => ({ ok: true, data: ROUTES }) },
			log: (msg) => push(logs, msg),
		};
		let out = exposition.recorder(nat_traffic.meta.max_samples);
		let res = nat_traffic.collect(deps, out, { peers: true });
		let s = out.families()[0].lines;

		assert.match([ true, nat_traffic.MAX_PAIRS + 2, 'node_nat_traffic_bytes{host="10.0.0.0",peer="other"} 10',
			'node_nat_traffic_bytes{host="10.0.0.1",peer="other"} 11' ],
			[ res.ok, length(s), s[nat_traffic.MAX_PAIRS / 2], s[length(s) - 1] ]);
		assert.match([ `2 pairs past the ${nat_traffic.MAX_PAIRS} it writes, written as peer "other" of their hosts` ], logs);
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

describe('collectors.nat_traffic.local_prefixes', () => {
	it('takes the router\'s own addresses and the on-link routes of interfaces without a default route', () => {
		let c = rtnl_const();
		let routes = [
			route(null, 'eth1', { gateway: '100.64.0.254' }),
			{ family: 2, type: 1, table: 2, dst: '0.0.0.0/0', oif: 'wwan0', gateway: '10.64.0.1' },
			route(null, null, { multipath: [ { oif: 'pppoe-wan', gateway: '192.0.2.1' }, { dev: 'wg0' } ] }),
			route('100.64.0.0/10', 'eth1'),
			route('10.64.0.0/24', 'wwan0'),
			route('10.9.0.0/24', 'wg0'),
			route('10.0.0.0/24', 'br-lan'),
			route('fd00::/64', 'br-lan'),
			route('10.1.0.0/24', 'br-lan', { gateway: '10.0.0.254' }),
			route('10.2.0.0/24', null, { multipath: [ { oif: 'br-lan' } ] }),
			route('2001:db8:1::/56', 'lo', { type: 7 }),
			route('10.5.0.0/24', 'lo'),
			own('100.64.0.1', 'eth1'),
			{ family: 2, type: 3, table: 255, dst: '10.0.0.255/32', oif: 'br-lan' },
		];

		assert.match([ [ [ 10, 0, 0, 0 ], 24 ], [ iptoarr('fd00::'), 64 ], [ [ 100, 64, 0, 1 ], 32 ] ],
			nat_traffic.local_prefixes(routes, c));
	});

	// The check the matcher replaced: each prefix in turn, a byte at a time.
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

	function bytes(n, seed) {
		let out = [];

		for (let i = 0; i < n; i++)
			push(out, (seed[i % length(seed)] * (i + 7)) & 0xff);

		return out;
	}

	// conntrack writes an IPv6 address uncompressed, the tests compressed too.
	function text(a) {
		return (length(a) == 4) ? arrtoip(a) : sprintf('%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x', ...a);
	}

	prop('the matcher takes an address a prefix holds, as checking each prefix does, whatever the lengths',
		gen.tuple(gen.array(gen.tuple(gen.bool(), gen.array(gen.int(0, 255), { min_len: 1, max_len: 4 }), gen.int(1, 128)), { min_len: 1, max_len: 8 }),
			gen.array(gen.tuple(gen.bool(), gen.int(0, 7), gen.int(0, 128), gen.bool()), { min_len: 1, max_len: 12 })), (t) => {
			let prefixes = map(t[0], (p) => {
				let a = bytes(p[0] ? 16 : 4, p[1]);

				return [ a, p[0] ? p[2] : 1 + (p[2] % 32) ];
			});
			let is_here = nat_traffic.matcher(prefixes);

			for (let x in t[1]) {
				let base = prefixes[x[1] % length(prefixes)][0];
				let a = [ ...base ];
				let bit = x[2] % (length(a) * 8);

				// A neighbour of a prefix's address, a bit flipped, or another family's.
				if (x[3])
					a[bit >> 3] ^= 0x80 >> (bit & 7);
				else if (x[2] % 5 == 0)
					a = bytes(length(a) == 4 ? 16 : 4, a);

				let want = length(filter(prefixes, (p) => within(a, p))) > 0;

				assert.match(want, is_here(text(a)), sprintf('%s in %J', text(a), map(prefixes, (p) => `${arrtoip(p[0])}/${p[1]}`)));
				assert.match(want, is_here(arrtoip(a)), arrtoip(a));
			}
		});

	it('takes an address within a prefix, of either family, and nothing else', () => {
		let p = nat_traffic.local_prefixes([ route('10.0.0.0/23', 'br-lan'), route('2001:db8:1:10::/61', 'br-lan'), own('100.64.0.1', 'eth1') ], rtnl_const());

		assert.match([ true, true, false, false, true, true, false, true, false, false, false ],
			map([ '10.0.0.7', '10.0.1.255', '10.0.2.0', '9.255.255.255', '2001:0db8:0001:0017:0000:0000:0000:0001', '2001:db8:1:10::',
				'2001:db8:1:18::1', '100.64.0.1', '100.64.0.2', 'other', '::ffff:10.0.0.7' ], (a) => nat_traffic.is_local(p, a)));
	});
});
