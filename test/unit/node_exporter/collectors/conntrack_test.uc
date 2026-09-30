'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as conntrack from 'node_exporter.collectors.conntrack';

const COUNT = '/proc/sys/net/netfilter/nf_conntrack_count';
const MAX = '/proc/sys/net/netfilter/nf_conntrack_max';

const ROUTER = fixtures.files('caju-router', [ COUNT, MAX ]);

function files(count, max) {
	return { fs: { data: { [COUNT]: count, [MAX]: max } } };
}

describe('collectors.conntrack', () => {
	it('exports the entries and the limit of the caju router', () => {
		with_collector(conntrack, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_nf_conntrack_entries Number of currently allocated flow entries for connection tracking.',
				'# TYPE node_nf_conntrack_entries gauge',
				'node_nf_conntrack_entries 297',
				'# HELP node_nf_conntrack_entries_limit Maximum size of connection tracking table.',
				'# TYPE node_nf_conntrack_entries_limit gauge',
				'node_nf_conntrack_entries_limit 65536',
			], r.lines);
		});
	});

	// The caju AP runs no firewall: nf_conntrack is not loaded and neither file is there.
	it('succeeds with nothing to say without nf_conntrack, as on the caju AP', () => {
		with_collector(conntrack, files(null, null), (r) => {
			assert.match([ true, [], [] ], [ r.result.ok, r.lines, r.logs ]);
		});
	});

	it('fails with SOURCE_UNREADABLE when only the entries cannot be read', () => {
		with_collector(conntrack, files(null, '65536\n'), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: COUNT },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('keeps the entries when only the limit cannot be read', () => {
		with_collector(conntrack, files('12\n', null), (r) => {
			assert.match({ error: 'SOURCE_UNREADABLE', details: MAX }, { error: r.result.error, details: r.result.details });
			assert.match('node_nf_conntrack_entries 12', r.lines[-1]);
		});
	});

	it('fails with SOURCE_INVALID for a value that is not a count', () => {
		with_collector(conntrack, files('\n', '65536\n'), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: `${COUNT}: ""` }, { error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	prop('exports whatever counts the kernel reports',
		gen.tuple(gen.int(0, 1 << 31), gen.int(0, 1 << 31)), (v) => {
			with_collector(conntrack, files(`${v[0]}\n`, `${v[1]}\n`), (r) => {
				assert.match(true, r.result.ok);
				assert.match([ `node_nf_conntrack_entries ${v[0]}`, `node_nf_conntrack_entries_limit ${v[1]}` ],
					filter(r.lines, (l) => substr(l, 0, 1) != '#'));
			});
		});
});
