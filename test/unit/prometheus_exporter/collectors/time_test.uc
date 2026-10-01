'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as time_collector from 'prometheus_exporter.collectors.time';

describe('collectors.time', () => {
	it('exports the system clock', () => {
		with_collector(time_collector, { time: 1790812800 }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_time_seconds System time in seconds since epoch (1970).',
				'# TYPE node_time_seconds gauge',
				'node_time_seconds 1790812800',
			], r.lines);
		});
	});

	it('keeps the fraction of a clock that has one', () => {
		with_collector(time_collector, { time: 1790812800.5 }, (r) => {
			assert.match([ 'node_time_seconds 1790812800.5' ], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('fails with SOURCE_INVALID for a clock that gives no number', () => {
		with_collector(time_collector, { time: 'noon' }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: 'clock: "noon"' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	prop('exports whatever second the clock says', gen.int(0, 4294967295), (now) => {
		with_collector(time_collector, { time: now }, (r) => {
			assert.match([ `node_time_seconds ${now}` ], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});
});
