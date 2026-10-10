'use strict';

// The template collector's tests, on the exporter's devkit: with_collector
// runs it as a scrape does, in the filesystem the service's jail gives it,
// and fails a test whose collector touches what its meta does not declare.
// Its fixtures are what a router answered, under fixtures/router/.

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome, assert_module } from 'prometheus.exporter.devkit.collector';
import { reader } from 'prometheus.exporter.devkit.fixtures';
import * as example from 'prometheus.collectors.example';

// This file's directory: utest may run from anywhere.
const HERE = sourcepath(0, true);
const ROUTER = reader(`${HERE}/fixtures/router`);
const FILES = ROUTER.files([ '/proc/uptime', '/proc/swaps' ]);

describe('collectors.example', () => {
	it('is a module the exporter loads: strict, the API alone, a top level that only declares', () => {
		assert_module(`${HERE}/../src/prometheus/collectors/example.uc`);
	});

	it('writes the uptime and each swap area of the router', () => {
		with_collector(example, { fs: { data: FILES } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP example_uptime_seconds_total Seconds since the system booted.',
				'# TYPE example_uptime_seconds_total counter',
				'example_uptime_seconds_total 350735.47',
				'# HELP example_idle_seconds_total Seconds the CPUs spent idle since boot, summed.',
				'# TYPE example_idle_seconds_total counter',
				'example_idle_seconds_total 1234388.9',
				'# HELP example_swap_size_bytes Size of the swap area.',
				'# TYPE example_swap_size_bytes gauge',
				'example_swap_size_bytes{device="/dev/zram0",type="partition"} 251654144',
				'# HELP example_swap_used_bytes Bytes of the swap area in use.',
				'# TYPE example_swap_used_bytes gauge',
				'example_swap_used_bytes{device="/dev/zram0",type="partition"} 1048576',
			], r.lines);
		});
	});

	it('writes no swap area with its option swaps off, nor reads /proc/swaps', () => {
		with_collector(example, { fs: { data: { '/proc/uptime': FILES['/proc/uptime'] } }, options: { swaps: '0' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'example_uptime_seconds_total', 'example_idle_seconds_total' ], map(r.families, (f) => f.name));
		});
	});

	it('writes none where there is no swap, the header alone', () => {
		with_collector(example, { fs: { data: { ...FILES, '/proc/swaps': 'Filename\tType\tSize\tUsed\tPriority\n' } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, 'example_swap_size_bytes' in map(r.families, (f) => f.name));
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/uptime cannot be read', () => {
		with_collector(example, { fs: { data: { '/proc/uptime': null } } }, (r) => {
			assert.match({ ok: false, none: null, error: 'SOURCE_UNREADABLE', lines: [], logs: [ "collector 'example': SOURCE_UNREADABLE (/proc/uptime)" ] },
				outcome(r));
		});
	});

	it('fails with SOURCE_INVALID for a line it cannot read, keeping what it wrote before', () => {
		with_collector(example, { fs: { data: { ...FILES, '/proc/swaps': 'Filename Type Size Used Priority\n/dev/sda2 partition many 0 -2\n' } } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match(contains([ 'example_uptime_seconds_total 350735.47' ]), r.lines);
		});
	});

	prop('writes whatever seconds the kernel reports', gen.tuple(gen.int(0, 100000000), gen.int(0, 99)), (t) => {
		let uptime = sprintf('%d.%02d %d.%02d\n', t[0], t[1], t[0] * 4, t[1]);

		with_collector(example, { fs: { data: { '/proc/uptime': uptime } }, options: { swaps: '0' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([ `example_uptime_seconds_total ${+sprintf('%d.%02d', t[0], t[1])}` ]), r.lines);
		});
	});
});
