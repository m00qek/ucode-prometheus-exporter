'use strict';

import { describe, it, prop, gen, assert, contains, mock } from 'utest';
import { with_collector } from 'prometheus_exporter.devkit.collector';
import * as exporter from 'prometheus_exporter.collectors.exporter';
import * as deps from 'prometheus_exporter.deps';
import * as exposition from 'prometheus_exporter.exposition';
import * as Result from 'prometheus_exporter.result';

// A uhttpd instance of pid 1234 that started 4 s (400 ticks) after boot, with
// 1.5 s of its own CPU and 12.25 s of its reaped scrapes', as a 24Kc router's.
const STAT = '1234 (uhttpd) S 1 1234 1234 0 -1 4194560 2600 91000 0 0 100 50 1000 225 20 0 1 0 400 3485696 520 4294967295 4194304 4196000 2147418720 0 0 0 0 4096 2 0 0 0 17 0 0 0 0 0 0\n';
const STATUS = 'Name:\tuhttpd\nVmPeak:\t    3404 kB\nVmSize:\t    3404 kB\nVmRSS:\t    2080 kB\nThreads:\t1\n';
const LIMITS = 'Limit                     Soft Limit           Hard Limit           Units     \n' +
	'Max cpu time              unlimited            unlimited            seconds   \n' +
	'Max open files            1024                 4096                 files     \n';
const PROC_STAT = 'cpu  1 2 3 4\nbtime 1790000000\nprocesses 4242\n';

// The 32-bit little-endian vector of a mipsel router: the page size and the
// clock tick among others.
function vector(pairs) {
	let s = '';

	for (let p in [ ...pairs, [ 0, 0 ] ])
		for (let v in p)
			for (let i = 0; i < 4; i++)
				s += chr((v >> (8 * i)) & 0xff);

	return s;
}

const AUXV = vector([ [ 16, 0x8ff ], [ 6, 4096 ], [ 17, 100 ], [ 3, 0x400034 ] ]);

function files(pid, extra) {
	return {
		[`/proc/${pid}/stat`]: STAT, [`/proc/${pid}/status`]: STATUS, [`/proc/${pid}/limits`]: LIMITS,
		[`/proc/${pid}/fd/0`]: '', [`/proc/${pid}/fd/1`]: '', [`/proc/${pid}/fd/2`]: '', [`/proc/${pid}/fd/3`]: '', [`/proc/${pid}/fd/5`]: '',
		'/proc/stat': PROC_STAT, '/proc/self/auxv': AUXV,
		...(extra ?? {}),
	};
}

const COUNTERS = {
	scrapes: 42, auth_failures: 3, collectors: {
		'nft-counters': { failures: { COMMAND_TIMEOUT: 2, COMMAND_FAILED: 1 }, timeouts: 2, quarantines: 1, deadline_skips: 0 },
		cpu: { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 0 },
		nat_traffic: { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 5 },
	},
};

// The collector as a scrape of the handler runs it: its capability over
// `data`, with the scrape's view.
function run(data, view) {
	let out;

	mock.inject('fs', { strict: true, data }, function(fs) {
		let rec = exposition.recorder();
		let res = exporter.collect({ exporter: deps.exporter_channel(fs, view) }, rec);
		let text = exposition.render(rec.families());

		out = { result: res, text, lines: (text == '') ? [] : split(rtrim(text, '\n'), '\n'), parsed: exposition.parse(text) };
	});

	return out;
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.exporter', () => {
	it('describes the serving process as Prometheus\'s client libraries do, its scrapes\' CPU in its own', () => {
		let r = run(files(1234), { pid: 1234, counters: null, samples: {} });

		assert.match([ true, true ], [ r.result.ok, r.parsed.ok ]);
		assert.match([
			'process_cpu_seconds_total 13.75',
			'process_virtual_memory_bytes 3485696',
			'process_resident_memory_bytes 2129920',
			'process_start_time_seconds 1790000004',
			'process_open_fds 5',
			'process_max_fds 1024',
		], samples(r.lines));
		assert.match(contains([ '# TYPE process_cpu_seconds_total counter', '# TYPE process_open_fds gauge' ]), r.lines);
	});

	it('writes the ledger\'s counters, by collector and by code, and this scrape\'s samples', () => {
		let r = run(files(1234), { pid: 1234, counters: COUNTERS, samples: { cpu: 46, 'nft-counters': 0, loadavg: 3 } });

		assert.match(contains([
			'ucode_prometheus_exporter_scrapes_total 42',
			'ucode_prometheus_exporter_auth_failures_total 3',
			'ucode_prometheus_exporter_collector_failures_total{collector="nft-counters",reason="COMMAND_FAILED"} 1',
			'ucode_prometheus_exporter_collector_failures_total{collector="nft-counters",reason="COMMAND_TIMEOUT"} 2',
			'ucode_prometheus_exporter_program_timeouts_total{collector="cpu"} 0',
			'ucode_prometheus_exporter_program_timeouts_total{collector="nft-counters"} 2',
			'ucode_prometheus_exporter_quarantines_total{collector="nft-counters"} 1',
			'ucode_prometheus_exporter_deadline_skips_total{collector="nat_traffic"} 5',
			'ucode_prometheus_exporter_collector_samples{collector="cpu"} 46',
			'ucode_prometheus_exporter_collector_samples{collector="loadavg"} 3',
			'ucode_prometheus_exporter_collector_samples{collector="nft-counters"} 0',
		]), r.lines);
		assert.match(true, r.parsed.ok);
	});

	it('leaves the counters out where there is no ledger, as on the command line', () => {
		let r = run(files('self'), null);

		assert.match([ true, -1 ], [ r.result.ok, index(r.text, 'ucode_prometheus_exporter_scrapes_total') ]);
		assert.match(contains([ 'process_cpu_seconds_total 13.75' ]), r.lines);
	});

	it('takes a clock tick of 100 where the vector says none, and leaves out what /proc does not say', () => {
		let r = run({ '/proc/9/stat': STAT, '/proc/9/status': null, '/proc/9/limits': null, '/proc/9/fd/0': null, '/proc/stat': 'cpu 1 2\n', '/proc/self/auxv': null }, { pid: 9 });

		assert.match([ 'process_cpu_seconds_total 13.75', 'process_virtual_memory_bytes 3485696', 'process_open_fds 0' ], samples(r.lines));
	});

	it('takes no maximum of descriptors that is unlimited', () => {
		let r = run(files(7, { '/proc/7/limits': 'Max open files            unlimited            unlimited            files\n' }), { pid: 7 });

		assert.match(-1, index(r.text, 'process_max_fds'));
	});

	it('fails with SOURCE_UNREADABLE without the process\'s stat, and still writes the counters', () => {
		let r = run({ '/proc/3/stat': null, '/proc/stat': PROC_STAT }, { pid: 3, counters: COUNTERS, samples: {} });

		assert.match('SOURCE_UNREADABLE', r.result.error);
		assert.match(contains([ 'ucode_prometheus_exporter_scrapes_total 42' ]), r.lines);
	});

	it('runs as a scrape runs it, on this process, needing nothing but its capability', () => {
		with_collector(exporter, { fs: { data: files('self') } }, (r) => {
			assert.match([ true, [ 'exporter' ] ], [ r.result.ok, exporter.meta.needs ]);
			assert.match(contains([ 'process_open_fds 5' ]), r.lines);
		});
	});

	prop('reads any stat line whose command holds spaces and parentheses', gen.string({ min_len: 1, max_len: 15, charset: 'ab )(' }), (comm) => {
		let s = exporter.parse_stat(replace(STAT, '(uhttpd)', `(${comm})`));

		assert.match({ cpu: 1375, start: 400, vsize: 3485696 }, s);
	});

	it('reads nothing of a stat line that is not one', () => {
		assert.match([ null, null, null ], map([ null, '12 (x) S 1', '1 (x) S a b c d e f g h i j k l m n o p q r s t u v' ], exporter.parse_stat));
	});
});
