'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus_exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as sockstat from 'prometheus_exporter.collectors.sockstat';

const V4 = sockstat.SOCKSTAT, V6 = sockstat.SOCKSTAT6, AUXV = sockstat.AUXV;
const ROUTER = fixtures.files('seriguela-router', [ V4, V6, AUXV ]);
const AP = fixtures.files('caju-ap', [ V4, V6, AUXV ]);

// An auxiliary vector of `pairs` ([ type, value ]), with its AT_NULL, in
// words of `size` bytes, little-endian or not.
function auxv(pairs, size, le) {
	let s = '';

	for (let p in [ ...pairs, [ 0, 0 ] ])
		for (let v in p)
			for (let i = 0; i < size; i++) {
				let shift = 8 * (le ? i : size - 1 - i);
				s += chr(shift < 32 ? (v >> shift) & 0xff : (v / 4294967296 >> (shift - 32)) & 0xff);
			}

	return s;
}

// What a process's vector holds: an address, the hardware's capabilities, the page size, a clock tick.
function process_pairs(page) {
	return [ [ 33, 0x7f8223d000 ], [ 16, 0x8ff ], [ 6, page ], [ 17, 100 ], [ 3, 0x400040 ], [ 25, 0x7ffe1234 ] ];
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

// sockstat6 is not there unless `v6` says what it holds.
function fs_of(v4, v6, auxv_text) {
	let data = { [V4]: v4, [V6]: v6, [AUXV]: auxv_text };

	return { data, behavior: { stat: (p) => data[p] != null ? { type: 'file' } : null } };
}

describe('collectors.sockstat', () => {
	it("exports the seriguela router's IPv4 and IPv6 sockets, by node_exporter's names", () => {
		with_collector(sockstat, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_sockstat_sockets_used 165',
				'node_sockstat_TCP_inuse 46',
				'node_sockstat_TCP_orphan 0',
				'node_sockstat_TCP_tw 2',
				'node_sockstat_TCP_alloc 55',
				'node_sockstat_TCP_mem 0',
				'node_sockstat_TCP_mem_bytes 0',
				'node_sockstat_UDP_inuse 20',
				'node_sockstat_UDP_mem 0',
				'node_sockstat_UDP_mem_bytes 0',
				'node_sockstat_UDPLITE_inuse 0',
				'node_sockstat_RAW_inuse 1',
				'node_sockstat_FRAG_inuse 0',
				'node_sockstat_FRAG_memory 0',
				'node_sockstat_TCP6_inuse 9',
				'node_sockstat_UDP6_inuse 8',
				'node_sockstat_UDPLITE6_inuse 0',
				'node_sockstat_RAW6_inuse 2',
				'node_sockstat_FRAG6_inuse 0',
				'node_sockstat_FRAG6_memory 0',
			], samples(r.lines));
		});
	});

	it("writes node_exporter's help texts, every family a gauge", () => {
		with_collector(sockstat, { fs: { data: AP } }, (r) => {
			assert.match(contains([
				'# HELP node_sockstat_sockets_used Number of IPv4 sockets in use.',
				'# TYPE node_sockstat_sockets_used gauge',
				'node_sockstat_sockets_used 87',
				'# HELP node_sockstat_TCP_tw Number of TCP sockets in state tw.',
				'# TYPE node_sockstat_TCP_tw gauge',
				'# HELP node_sockstat_TCP_mem_bytes Number of TCP sockets in state mem_bytes.',
				'# HELP node_sockstat_TCP6_inuse Number of TCP6 sockets in state inuse.',
				'node_sockstat_TCP6_inuse 2',
			]), r.lines);
			assert.match([ 'gauge' ], uniq(map(r.families, (f) => f.type)));
		});
	});

	it('exports the memory in pages, and in bytes by the page size of the auxiliary vector', () => {
		let v4 = 'sockets: used 3\nTCP: inuse 2 orphan 0 tw 0 alloc 2 mem 102\nUDP: inuse 1 mem 7\n';

		with_collector(sockstat, { fs: fs_of(v4, null, auxv(process_pairs(16384), 8, true)) }, (r) => {
			assert.match(contains([ 'node_sockstat_TCP_mem 102', 'node_sockstat_TCP_mem_bytes 1671168',
				'node_sockstat_UDP_mem 7', 'node_sockstat_UDP_mem_bytes 114688' ]), r.lines);
		});
	});

	it('leaves out the memory in bytes where the auxiliary vector says no page size', () => {
		let v4 = 'sockets: used 3\nTCP: inuse 2 orphan 0 tw 0 alloc 2 mem 102\n';

		for (let a in [ null, '', 'garbage!', auxv([ [ 16, 0x8ff ] ], 8, true) ])
			with_collector(sockstat, { fs: fs_of(v4, null, a) }, (r) => {
				assert.match(true, r.result.ok);
				assert.match([ 'node_sockstat_sockets_used 3', 'node_sockstat_TCP_inuse 2', 'node_sockstat_TCP_orphan 0',
					'node_sockstat_TCP_tw 0', 'node_sockstat_TCP_alloc 2', 'node_sockstat_TCP_mem 102' ], samples(r.lines));
			});
	});

	it('exports IPv4 alone, successfully, without sockstat6 (IPv6 disabled)', () => {
		with_collector(sockstat, { fs: fs_of(AP[V4], null, AP[AUXV]) }, (r) => {
			assert.match([ true, null, [] ], [ r.result.ok, r.result.none, r.logs ]);
			assert.match(14, length(samples(r.lines)));
			assert.match([], filter(r.lines, (l) => match(l, /6_/)));
		});
	});

	it('fails with SOURCE_UNREADABLE without /proc/net/sockstat', () => {
		with_collector(sockstat, { fs: fs_of(null, AP[V6], AP[AUXV]) }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: V4 },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_UNREADABLE when sockstat6 is there and cannot be read', () => {
		let fs = { data: { [V4]: AP[V4], [V6]: null, [AUXV]: AP[AUXV] }, behavior: { stat: () => ({ type: 'file' }) } };

		with_collector(sockstat, { fs }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: V6, lines: [] },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details, lines: r.lines });
		});
	});

	it('fails with SOURCE_INVALID for a malformed line, as procfs does, and writes nothing', () => {
		for (let bad in [ 'TCP: inuse', 'TCP: inuse 1 orphan', 'TCP: inuse x', 'TCP:  inuse 1', 'TCP: inuse 1.5' ])
			with_collector(sockstat, { fs: fs_of(`sockets: used 1\n${bad}\n`, null, null) }, (r) => {
				assert.match({ ok: false, error: 'SOURCE_INVALID', lines: [] }, { ok: r.result.ok, error: r.result.error, lines: r.lines }, bad);
				assert.match(0, index(r.result.details, `${V4}: line 2: `), bad);
			});
		with_collector(sockstat, { fs: fs_of(AP[V4], 'TCP6: inuse\n', null) }, (r) => {
			assert.match([ 'SOURCE_INVALID', 0, [] ], [ r.result.error, index(r.result.details, `${V6}: line 1: `), r.lines ]);
		});
	});

	it('exports a protocol without inuse at 0, and leaves out keys node_exporter does not know', () => {
		with_collector(sockstat, { fs: fs_of('sockets: used 1\nNEW: alloc 3 pressure 1\n', null, null) }, (r) => {
			assert.match([ 'node_sockstat_sockets_used 1', 'node_sockstat_NEW_inuse 0', 'node_sockstat_NEW_alloc 3' ], samples(r.lines));
		});
	});

	it("reads the caju AP's and the seriguela router's page size, 4 KiB", () => {
		assert.match([ 4096, 4096 ], [ sockstat.page_size(AP[AUXV]), sockstat.page_size(ROUTER[AUXV]) ]);
	});

	prop('reads the page size of a vector of any word size and byte order',
		gen.tuple(gen.elements(4096, 8192, 16384, 65536), gen.elements(4, 8), gen.elements(true, false)), (t) => {
			assert.match(t[0], sockstat.page_size(auxv(process_pairs(t[0]), t[1], t[2])), sprintf('%J', t));
		});

	prop('exports every protocol and key of a sockstat line',
		gen.array(gen.tuple(gen.elements('TCP', 'UDP', 'RAW', 'FRAG', 'SCTP'), gen.int(0, 100000), gen.int(0, 100000)),
			{ min_len: 1, max_len: 6 }), (rows) => {
			let seen = {};
			rows = filter(rows, (r) => !seen[r[0]] && (seen[r[0]] = true));

			let text = 'sockets: used 9\n' + join('', map(rows, (r) => `${r[0]}: inuse ${r[1]} alloc ${r[2]} mem ${r[2]}\n`));
			let want = [ 'node_sockstat_sockets_used 9' ];
			for (let r in rows)
				push(want, `node_sockstat_${r[0]}_inuse ${r[1]}`, `node_sockstat_${r[0]}_alloc ${r[2]}`,
					`node_sockstat_${r[0]}_mem ${r[2]}`, `node_sockstat_${r[0]}_mem_bytes ${r[2] * 4096}`);

			with_collector(sockstat, { fs: fs_of(text, null, AP[AUXV]) }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(want), sort(samples(r.lines)));
			});
		});
});
