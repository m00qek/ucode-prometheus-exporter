'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'context';
import * as fixtures from 'lib.fixtures';
import * as nat_traffic from 'prometheus_exporter.collectors.nat_traffic';

// The caju router's conntrack table, public addresses mapped to documentation
// ranges (its CGNAT WAN address to 100.64.0.1).
const CONNTRACK = fixtures.file('caju-router', '/proc/net/nf_conntrack');

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

function with_table(text, cb) {
	with_collector(nat_traffic, { fs: { data: { '/proc/net/nf_conntrack': text } } }, cb);
}

// A conntrack entry as the kernel writes it, with accounting on.
function entry(src, dst, out_bytes, in_bytes) {
	return `ipv4     2 tcp      6 7428 ESTABLISHED src=${src} dst=${dst} sport=55465 dport=443 ` +
		`packets=1 bytes=${out_bytes} src=${dst} dst=100.64.0.1 sport=443 dport=55465 ` +
		`packets=1 bytes=${in_bytes} [ASSURED] mark=0 zone=0 use=2\n`;
}

describe('collectors.nat_traffic', () => {
	it('sums both directions per source and destination, in the order the pairs appear', () => {
		with_table(head(CONNTRACK, 12), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_nat_traffic_bytes Bytes of the connections from src to dst, both directions.',
				'# TYPE node_nat_traffic_bytes gauge',
				'node_nat_traffic_bytes{src="10.193.13.193",dst="192.0.2.1"} 534196',
				'node_nat_traffic_bytes{src="10.193.13.193",dst="192.0.2.3"} 65061',
				'node_nat_traffic_bytes{src="10.193.13.193",dst="192.0.2.5"} 57450692',
				'node_nat_traffic_bytes{src="10.193.13.193",dst="192.0.2.6"} 15606',
				'node_nat_traffic_bytes{src="10.193.13.193",dst="192.0.2.8"} 80406',
				'node_nat_traffic_bytes{src="10.193.13.116",dst="192.0.2.2"} 52647',
				'node_nat_traffic_bytes{src="10.193.13.116",dst="192.0.2.7"} 9989',
				'node_nat_traffic_bytes{src="10.193.13.116",dst="192.0.2.9"} 46492',
				'node_nat_traffic_bytes{src="10.193.13.100",dst="192.0.2.4"} 43626',
				// Two SSH connections, 4974 + 6018 and 6814 + 25266 bytes.
				'node_nat_traffic_bytes{src="10.251.223.1",dst="10.193.11.1"} 43072',
				'node_nat_traffic_bytes{src="10.193.17.70",dst="192.0.2.10"} 9133',
			], r.lines);
		});
	});

	it('accounts for every byte of the whole caju router table, IPv6 too', () => {
		with_table(CONNTRACK, (r) => {
			assert.match(true, r.result.ok);
			assert.match(75, length(samples(r.lines)));
			assert.match(242156839, total(r.lines));
			assert.match(contains([
				'node_nat_traffic_bytes{src="2001:0db8:0000:0001:0000:0000:0000:e157",dst="2001:0db8:0000:0002:0000:0000:0000:0001"} 77100',
			]), r.lines);
		});
	});

	it('gives 0 for connections without accounting', () => {
		with_table('ipv4     2 udp      17 29 src=10.0.0.2 dst=198.51.100.7 sport=5353 dport=5353 [UNREPLIED] ' +
				'src=198.51.100.7 dst=10.0.0.2 sport=5353 dport=5353 mark=0 zone=0 use=2\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{src="10.0.0.2",dst="198.51.100.7"} 0' ], samples(r.lines));
		});
	});

	it('skips lines without both addresses', () => {
		with_table('garbage\n' + entry('10.0.0.2', '192.0.2.1', 1, 2) + 'ipv4 2 tcp 6 1 src=10.0.0.3 bytes=9\n', (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_nat_traffic_bytes{src="10.0.0.2",dst="192.0.2.1"} 3' ], samples(r.lines));
		});
	});

	// Addresses as a table could hold them, if not as the kernel writes them:
	// the labels are still escaped, and a third bytes= still counts.
	it('escapes what an address would need escaped, and sums every bytes=', () => {
		with_table('ipv4 2 tcp 6 1 src=a"b dst=c\\d bytes=1 bytes=2 bytes=3\n', (r) => {
			assert.match([ 'node_nat_traffic_bytes{src="a\\"b",dst="c\\\\d"} 6' ], samples(r.lines));
		});
	});

	// The collector reads a line with index() and split() for speed; on any
	// line whose fields are separated by spaces, as the kernel writes them, it
	// must read what splitting it into fields and matching each would.
	const FIELD = /^(src|dst|bytes)=(.*)$/;

	function reference(text) {
		let totals = {}, out = [];

		for (let line in split(text, '\n')) {
			let t = trim(line);
			let e = { src: null, dst: null, bytes: 0 };

			for (let f in (t == '' ? [] : split(t, / +/))) {
				let m = match(f, FIELD);
				if (!m)
					continue;
				if (m[1] == 'bytes')
					e.bytes += +m[2] || 0;
				else if (m[1] == 'src')
					e.src ??= m[2];
				else
					e.dst ??= m[2];
			}

			if (e.src == null || e.dst == null)
				continue;
			totals[e.src] ??= {};
			totals[e.src][e.dst] = (totals[e.src][e.dst] ?? 0) + e.bytes;
		}

		for (let src, dsts in totals)
			for (let dst, b in dsts)
				push(out, `node_nat_traffic_bytes{src="${src}",dst="${dst}"} ${b}`);

		return out;
	}

	prop('reads any line of space-separated fields as matching each field would',
		gen.array(gen.array(gen.tuple(
			gen.elements('src=', 'dst=', 'bytes=', 'sport=', 'xsrc=', 'ipv4', '[ASSURED]'),
			gen.elements('', '1', '22', '10.0.0.1', 'fd00::1', '7x', 'bytes=3', 'src=b')),
			{ min_len: 0, max_len: 8 }), { min_len: 0, max_len: 6 }),
		(lines) => {
			let text = join('', map(lines, (fields) => join(' ', map(fields, (f) => f[0] + f[1])) + '\n'));

			with_table(text, (r) => assert.match(reference(text), samples(r.lines), text));
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

	prop('the sum of each pair is the bytes of its connections, both directions',
		gen.array(gen.tuple(gen.int(0, 2), gen.int(0, 2), gen.int(0, 100000000), gen.int(0, 100000000)),
			{ min_len: 0, max_len: 30 }), (conns) => {
			let text = '';
			let want = {};

			for (let c in conns) {
				let src = `10.0.0.${c[0]}`, dst = `192.0.2.${c[1]}`;
				let key = `node_nat_traffic_bytes{src="${src}",dst="${dst}"}`;

				text += entry(src, dst, c[2], c[3]);
				want[key] = (want[key] ?? 0) + c[2] + c[3];
			}

			with_table(text, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(want), (k) => `${k} ${want[k]}`)), sort(samples(r.lines)));
			});
		});
});
