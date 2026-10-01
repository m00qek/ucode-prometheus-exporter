'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as vmstat from 'prometheus_exporter.collectors.vmstat';

const PATH = vmstat.PATH;
const ROUTER = fixtures.files('caju-router', [ PATH ]);
const AP = fixtures.files('caju-ap', [ PATH ]);

function file(text, options) {
	return { fs: { data: { [PATH]: text } }, options };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.vmstat', () => {
	it("exports the caju router's paging, swapping, fault and OOM kill fields", () => {
		with_collector(vmstat, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_vmstat_pgpgin /proc/vmstat information field pgpgin.',
				'# TYPE node_vmstat_pgpgin untyped',
				'node_vmstat_pgpgin 421849',
				'# HELP node_vmstat_pgpgout /proc/vmstat information field pgpgout.',
				'# TYPE node_vmstat_pgpgout untyped',
				'node_vmstat_pgpgout 829904',
				'# HELP node_vmstat_pswpin /proc/vmstat information field pswpin.',
				'# TYPE node_vmstat_pswpin untyped',
				'node_vmstat_pswpin 0',
				'# HELP node_vmstat_pswpout /proc/vmstat information field pswpout.',
				'# TYPE node_vmstat_pswpout untyped',
				'node_vmstat_pswpout 0',
				'# HELP node_vmstat_pgfault /proc/vmstat information field pgfault.',
				'# TYPE node_vmstat_pgfault untyped',
				'node_vmstat_pgfault 3028925',
				'# HELP node_vmstat_pgmajfault /proc/vmstat information field pgmajfault.',
				'# TYPE node_vmstat_pgmajfault untyped',
				'node_vmstat_pgmajfault 1772',
				'# HELP node_vmstat_oom_kill /proc/vmstat information field oom_kill.',
				'# TYPE node_vmstat_oom_kill untyped',
				'node_vmstat_oom_kill 0',
			], r.lines);
		});
	});

	// The AP's kernel has no CONFIG_VM_EVENT_COUNTERS: only the nr_* gauges and a few others.
	it('succeeds with nothing to say on the caju AP, whose kernel counts no events', () => {
		with_collector(vmstat, { fs: { data: AP } }, (r) => {
			assert.match([ true, [] ], [ r.result.ok, r.lines ]);
		});
	});

	it('exports the fields the fields option matches', () => {
		with_collector(vmstat, { fs: { data: AP }, options: { fields: '^nr_(free_pages|dirty)$' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'node_vmstat_nr_free_pages 30727', 'node_vmstat_nr_dirty 0' ], samples(r.lines));
		});
	});

	it('fails with CONFIG_INVALID for a fields option that is no regular expression', () => {
		with_collector(vmstat, file('pgfault 1\n', { fields: '(pg' }), (r) => {
			assert.match({ ok: false, error: 'CONFIG_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match(true, index(r.result.details, 'fields: ') == 0);
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE without /proc/vmstat', () => {
		with_collector(vmstat, file(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: PATH },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('fails with SOURCE_INVALID for any malformed line, as node_exporter does', () => {
		for (let text in [ 'pgfault 1\nnr_dirty\n', 'pgfault 1\nnr_dirty x\n', 'pgfault 1 2\n' ])
			with_collector(vmstat, file(text), (r) => {
				assert.match('SOURCE_INVALID', r.result.error);
				assert.match([], r.lines);
			});
	});

	prop('exports exactly the fields of the default pattern, with their values',
		gen.array(gen.tuple(
			gen.oneof(gen.elements('pgfault', 'pgmajfault', 'pgpgin', 'pswpout', 'oom_kill', 'pgsteal_kswapd'),
				gen.alphanumeric({ min_len: 1, max_len: 10 })),
			gen.int(0, 1 << 40)), { max_len: 12 }), (rows) => {
			let seen = {};
			rows = filter(rows, (r) => !seen[r[0]] && (seen[r[0]] = true));

			let text = join('', map(rows, (r) => `${r[0]} ${r[1]}\n`));
			let want = map(filter(rows, (r) => match(r[0], /^(oom_kill|pgpg|pswp|pg.*fault)/)),
				(r) => `node_vmstat_${r[0]} ${r[1]}`);

			with_collector(vmstat, file(text), (r) => {
				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});
