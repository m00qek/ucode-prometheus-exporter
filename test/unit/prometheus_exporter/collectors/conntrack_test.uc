'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, outcome } from 'context';
import * as fixtures from 'lib.fixtures';
import * as conntrack from 'prometheus_exporter.collectors.conntrack';

const COUNT = '/proc/sys/net/netfilter/nf_conntrack_count';
const MAX = '/proc/sys/net/netfilter/nf_conntrack_max';
const STAT = conntrack.STAT;

const ROUTER = fixtures.files('caju-router', [ COUNT, MAX, STAT ]);

// The header of OpenWrt 25.12's kernels (6.12), as ct_cpu_seq_show() writes it.
const HEADER = 'entries  clashres found new invalid ignore delete chainlength insert insert_failed drop early_drop icmp_error  expect_new expect_create expect_delete search_restart';
const COLUMNS = split(HEADER, /\s+/);

// Before Linux 5.13 (and in procfs's positions): searched and delete_list,
// where clashres and chainlength are now.
const OLD_HEADER = 'entries  searched found new invalid ignore delete delete_list insert insert_failed drop early_drop icmp_error  expect_new expect_create expect_delete search_restart';

function files(count, max, stat) {
	return { fs: { data: { [COUNT]: count, [MAX]: max, [STAT]: stat } } };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function table(header, rows) {
	return header + '\n' + join('\n', map(rows, (r) => join(' ', map(r, (v) => sprintf('%08x', v))))) + '\n';
}

describe('collectors.conntrack', () => {
	it('exports the entries, the limit and the statistics of the caju router', () => {
		with_collector(conntrack, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_nf_conntrack_entries Number of currently allocated flow entries for connection tracking.',
				'# TYPE node_nf_conntrack_entries gauge',
				'node_nf_conntrack_entries 297',
				'# HELP node_nf_conntrack_entries_limit Maximum size of connection tracking table.',
				'# TYPE node_nf_conntrack_entries_limit gauge',
				'node_nf_conntrack_entries_limit 65536',
				'# HELP node_nf_conntrack_stat_found Number of searched entries which were successful.',
				'# TYPE node_nf_conntrack_stat_found gauge',
				'node_nf_conntrack_stat_found 3',
				'# HELP node_nf_conntrack_stat_invalid Number of packets seen which can not be tracked.',
				'# TYPE node_nf_conntrack_stat_invalid gauge',
				'node_nf_conntrack_stat_invalid 212',
				'# HELP node_nf_conntrack_stat_ignore Number of packets seen which are already connected to a conntrack entry.',
				'# TYPE node_nf_conntrack_stat_ignore gauge',
				'node_nf_conntrack_stat_ignore 0',
				'# HELP node_nf_conntrack_stat_insert Number of entries inserted into the list.',
				'# TYPE node_nf_conntrack_stat_insert gauge',
				'node_nf_conntrack_stat_insert 0',
				'# HELP node_nf_conntrack_stat_insert_failed Number of entries for which list insertion was attempted but failed.',
				'# TYPE node_nf_conntrack_stat_insert_failed gauge',
				'node_nf_conntrack_stat_insert_failed 0',
				'# HELP node_nf_conntrack_stat_drop Number of packets dropped due to conntrack failure.',
				'# TYPE node_nf_conntrack_stat_drop gauge',
				'node_nf_conntrack_stat_drop 0',
				'# HELP node_nf_conntrack_stat_early_drop Number of dropped conntrack entries to make room for new ones, if maximum table size was reached.',
				'# TYPE node_nf_conntrack_stat_early_drop gauge',
				'node_nf_conntrack_stat_early_drop 0',
				'# HELP node_nf_conntrack_stat_search_restart Number of conntrack table lookups which had to be restarted due to hashtable resizes.',
				'# TYPE node_nf_conntrack_stat_search_restart gauge',
				'node_nf_conntrack_stat_search_restart 0',
			], r.lines);
		});
	});

	// The caju AP runs no firewall: nf_conntrack is not loaded and no file is there.
	it('has nothing to observe without nf_conntrack, as on the caju AP', () => {
		with_collector(conntrack, files(null, null, null), (r) => {
			assert.match({ ok: true, none: 'no connection tracking (nf_conntrack is not loaded)', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('leaves the statistics out for a kernel without the statistics file', () => {
		with_collector(conntrack, files('12\n', '65536\n', null), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_nf_conntrack_entries 12', 'node_nf_conntrack_entries_limit 65536' ], samples(r.lines));
		});
	});

	it('reads the columns by name, as older kernels name them too', () => {
		let rows = [ [ 9, 1, 2, 0, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0, 10 ], [ 9, 1, 2, 0, 3, 4, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0, 10 ] ];

		for (let header in [ HEADER, OLD_HEADER ])
			with_collector(conntrack, files('9\n', '100\n', table(header, rows)), (r) => {
				assert.match(true, r.result.ok);
				assert.match([
					'node_nf_conntrack_entries 9', 'node_nf_conntrack_entries_limit 100',
					'node_nf_conntrack_stat_found 4', 'node_nf_conntrack_stat_invalid 6',
					'node_nf_conntrack_stat_ignore 8', 'node_nf_conntrack_stat_insert 10',
					'node_nf_conntrack_stat_insert_failed 12', 'node_nf_conntrack_stat_drop 14',
					'node_nf_conntrack_stat_early_drop 16', 'node_nf_conntrack_stat_search_restart 20',
				], samples(r.lines));
			});
	});

	it('leaves out a statistic whose column the kernel does not write', () => {
		let header = 'entries searched found new invalid ignore delete delete_list insert insert_failed drop early_drop icmp_error expect_new expect_create expect_delete';

		with_collector(conntrack, files('1\n', '2\n', table(header, [ [ 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ] ])), (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, 'node_nf_conntrack_stat_search_restart' in map(r.families, (f) => f.name));
			assert.match('node_nf_conntrack_stat_early_drop 0', samples(r.lines)[-1]);
		});
	});

	it('fails with SOURCE_UNREADABLE when only the entries cannot be read', () => {
		with_collector(conntrack, files(null, '65536\n', null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: COUNT },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('keeps the entries when only the limit cannot be read', () => {
		with_collector(conntrack, files('12\n', null, null), (r) => {
			assert.match({ error: 'SOURCE_UNREADABLE', details: MAX }, { error: r.result.error, details: r.result.details });
			assert.match('node_nf_conntrack_entries 12', r.lines[-1]);
		});
	});

	it('fails with SOURCE_INVALID for a value that is not a count', () => {
		with_collector(conntrack, files('\n', '65536\n', null), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: `${COUNT}: ""` }, { error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a malformed statistics table, keeping the entries', () => {
		let cases = [
			[ '', 'no header' ],
			[ HEADER + '\n', 'no rows' ],
			[ HEADER + '\n00000001 00000002\n', 'row 1: 2 columns for 17' ],
			[ 'entries found\n00000001 0000000g\n', 'row 1: "0000000g" is not hex' ],
		];

		for (let c in cases)
			with_collector(conntrack, files('1\n', '2\n', c[0]), (r) => {
				assert.match({ error: 'SOURCE_INVALID', details: `${STAT}: ${c[1]}` }, { error: r.result.error, details: r.result.details });
				assert.match([ 'node_nf_conntrack_entries 1', 'node_nf_conntrack_entries_limit 2' ], samples(r.lines));
			});
	});

	prop('exports whatever counts the kernel reports',
		gen.tuple(gen.int(0, 1 << 31), gen.int(0, 1 << 31)), (v) => {
			with_collector(conntrack, files(`${v[0]}\n`, `${v[1]}\n`, null), (r) => {
				assert.match(true, r.result.ok);
				assert.match([ `node_nf_conntrack_entries ${v[0]}`, `node_nf_conntrack_entries_limit ${v[1]}` ],
					samples(r.lines));
			});
		});

	prop('sums each statistic over every CPU row',
		gen.array(gen.array(gen.int(0, 0xffffffff), { len: length(COLUMNS) }), { min_len: 1, max_len: 16 }), (rows) => {
			let want = [];

			for (let s in conntrack.STATS) {
				let col = index(COLUMNS, s[0]);
				let sum = 0;

				for (let row in rows)
					sum += row[col];
				push(want, `node_nf_conntrack_stat_${s[0]} ${sum}`);
			}

			with_collector(conntrack, files('1\n', '2\n', table(HEADER, rows)), (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, slice(samples(r.lines), 2));
			});
		});
});
