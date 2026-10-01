'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as loadavg from 'prometheus_exporter.collectors.loadavg';

const ROUTER = fixtures.files('caju-router', [ '/proc/loadavg' ]);

describe('collectors.loadavg', () => {
	it('exports the 1, 5 and 15 minute averages of the caju router', () => {
		with_collector(loadavg, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_load1 1m load average.',
				'# TYPE node_load1 gauge',
				'node_load1 0.75',
				'# HELP node_load5 5m load average.',
				'# TYPE node_load5 gauge',
				'node_load5 0.48',
				'# HELP node_load15 15m load average.',
				'# TYPE node_load15 gauge',
				'node_load15 0.24',
			], r.lines);
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/loadavg cannot be read', () => {
		with_collector(loadavg, { fs: { data: { '/proc/loadavg': null } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
			assert.match([ "collector 'loadavg': SOURCE_UNREADABLE (/proc/loadavg)" ], r.logs);
		});
	});

	it('fails with SOURCE_INVALID for fewer than three fields', () => {
		with_collector(loadavg, { fs: { data: { '/proc/loadavg': '0.1 0.2\n' } } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	prop('exports whatever three non-negative averages the kernel reports',
		gen.tuple(gen.float(0, 64), gen.float(0, 64), gen.float(0, 64)), (avg) => {
			let line = sprintf('%.2f %.2f %.2f 1/100 4242\n', ...avg);

			with_collector(loadavg, { fs: { data: { '/proc/loadavg': line } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(contains([ 'node_load1 ' + (+sprintf('%.2f', avg[0])) ]), r.lines);
				assert.match(contains([ 'node_load15 ' + (+sprintf('%.2f', avg[2])) ]), r.lines);
			});
		});
});
