'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as cpu from 'prometheus_exporter.collectors.cpu';

const ROUTER = fixtures.files('caju-router', [ '/proc/stat' ]);
const AP = fixtures.files('caju-ap', [ '/proc/stat' ]);

const MODES = [ 'user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal' ];
const GUEST_MODES = [ 'user', 'nice' ];

function stat(text) {
	return { fs: { data: { '/proc/stat': text } } };
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.cpu', () => {
	it('exports the per-CPU times and the counters of the caju router', () => {
		with_collector(cpu, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.',
				'# TYPE node_cpu_seconds_total counter',
				'node_cpu_seconds_total{cpu="0",mode="user"} 196.8',
				'node_cpu_seconds_total{cpu="0",mode="nice"} 0',
				'node_cpu_seconds_total{cpu="0",mode="system"} 112.09',
				'node_cpu_seconds_total{cpu="0",mode="idle"} 11421.84',
				'node_cpu_seconds_total{cpu="0",mode="iowait"} 35.31',
				'node_cpu_seconds_total{cpu="0",mode="irq"} 52.39',
				'node_cpu_seconds_total{cpu="0",mode="softirq"} 49.23',
				'node_cpu_seconds_total{cpu="0",mode="steal"} 0',
				'node_cpu_seconds_total{cpu="1",mode="user"} 193.27',
				'node_cpu_seconds_total{cpu="1",mode="nice"} 0',
				'node_cpu_seconds_total{cpu="1",mode="system"} 103.79',
				'node_cpu_seconds_total{cpu="1",mode="idle"} 11429.98',
				'node_cpu_seconds_total{cpu="1",mode="iowait"} 53.74',
				'node_cpu_seconds_total{cpu="1",mode="irq"} 49.89',
				'node_cpu_seconds_total{cpu="1",mode="softirq"} 32.7',
				'node_cpu_seconds_total{cpu="1",mode="steal"} 0',
				'node_cpu_seconds_total{cpu="2",mode="user"} 197.33',
				'node_cpu_seconds_total{cpu="2",mode="nice"} 0',
				'node_cpu_seconds_total{cpu="2",mode="system"} 104.4',
				'node_cpu_seconds_total{cpu="2",mode="idle"} 11384.33',
				'node_cpu_seconds_total{cpu="2",mode="iowait"} 53.86',
				'node_cpu_seconds_total{cpu="2",mode="irq"} 49.27',
				'node_cpu_seconds_total{cpu="2",mode="softirq"} 76.82',
				'node_cpu_seconds_total{cpu="2",mode="steal"} 0',
				'node_cpu_seconds_total{cpu="3",mode="user"} 199.47',
				'node_cpu_seconds_total{cpu="3",mode="nice"} 0',
				'node_cpu_seconds_total{cpu="3",mode="system"} 99.09',
				'node_cpu_seconds_total{cpu="3",mode="idle"} 11446.34',
				'node_cpu_seconds_total{cpu="3",mode="iowait"} 57.39',
				'node_cpu_seconds_total{cpu="3",mode="irq"} 43.7',
				'node_cpu_seconds_total{cpu="3",mode="softirq"} 19.89',
				'node_cpu_seconds_total{cpu="3",mode="steal"} 0',
				'# HELP node_cpu_guest_seconds_total Seconds the CPUs spent in guests (VMs) for each mode.',
				'# TYPE node_cpu_guest_seconds_total counter',
				'node_cpu_guest_seconds_total{cpu="0",mode="user"} 0',
				'node_cpu_guest_seconds_total{cpu="0",mode="nice"} 0',
				'node_cpu_guest_seconds_total{cpu="1",mode="user"} 0',
				'node_cpu_guest_seconds_total{cpu="1",mode="nice"} 0',
				'node_cpu_guest_seconds_total{cpu="2",mode="user"} 0',
				'node_cpu_guest_seconds_total{cpu="2",mode="nice"} 0',
				'node_cpu_guest_seconds_total{cpu="3",mode="user"} 0',
				'node_cpu_guest_seconds_total{cpu="3",mode="nice"} 0',
				'# HELP node_intr_total Total number of interrupts serviced.',
				'# TYPE node_intr_total counter',
				'node_intr_total 11767415',
				'# HELP node_context_switches_total Total number of context switches.',
				'# TYPE node_context_switches_total counter',
				'node_context_switches_total 12849858',
				'# HELP node_boot_time_seconds Node boot time, in unixtime.',
				'# TYPE node_boot_time_seconds gauge',
				'node_boot_time_seconds 1790794406',
				'# HELP node_forks_total Total number of forks.',
				'# TYPE node_forks_total counter',
				'node_forks_total 22384',
				'# HELP node_procs_running Number of processes in runnable state.',
				'# TYPE node_procs_running gauge',
				'node_procs_running 1',
				'# HELP node_procs_blocked Number of processes blocked waiting for I/O to complete.',
				'# TYPE node_procs_blocked gauge',
				'node_procs_blocked 0',
			], r.lines);
		});
	});

	it('exports eight modes and two guest modes for each of the two CPUs of the caju AP, and not the aggregate line', () => {
		with_collector(cpu, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(16, length(filter(r.lines, (l) => match(l, /^node_cpu_seconds_total\{cpu="[01]"/))));
			assert.match(4, length(filter(r.lines, (l) => match(l, /^node_cpu_guest_seconds_total\{cpu="[01]"/))));
			assert.match(false, index(r.text, 'cpu="cpu') >= 0);
			assert.match(contains([
				'node_cpu_seconds_total{cpu="1",mode="system"} 97.23',
				'node_cpu_seconds_total{cpu="1",mode="idle"} 11713.01',
				'node_boot_time_seconds 1790794407',
			]), r.lines);
		});
	});

	it('exports only the modes an older kernel has columns for', () => {
		with_collector(cpu, stat('cpu  1 2 3 4 5 6 7\ncpu0 1 2 3 4 5 6 7\n'), (r) => {
			assert.match(true, r.result.ok);
			assert.match(7, length(samples(r.lines)));
			assert.match('node_cpu_seconds_total{cpu="0",mode="softirq"} 0.07', samples(r.lines)[-1]);
		});
	});

	it('leaves out the counters the file lacks', () => {
		with_collector(cpu, stat('cpu0 100 0 0 0\nctxt 42\n'), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_cpu_seconds_total{cpu="0",mode="user"} 1',
				'node_cpu_seconds_total{cpu="0",mode="nice"} 0',
				'node_cpu_seconds_total{cpu="0",mode="system"} 0',
				'node_cpu_seconds_total{cpu="0",mode="idle"} 0',
				'node_context_switches_total 42',
			], samples(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE when /proc/stat cannot be read', () => {
		with_collector(cpu, stat(null), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/stat' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
			assert.match([ "collector 'cpu': SOURCE_UNREADABLE (/proc/stat)" ], r.logs);
		});
	});

	it('fails with SOURCE_INVALID, exporting nothing, for a cpu line that is not all numbers', () => {
		with_collector(cpu, stat('cpu0 1 2 3 4\ncpu1 1 x 3 4\nctxt 42\n'), (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: '/proc/stat: "cpu1 1 x 3 4"' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a cpu line without times', () => {
		with_collector(cpu, stat('cpu0\n'), (r) => assert.match('SOURCE_INVALID', r.result.error));
	});

	it('fails with SOURCE_INVALID for a file without cpu lines', () => {
		with_collector(cpu, stat('ctxt 42\nbtime 1\n'), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: '/proc/stat: no cpu lines' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	prop('exports every jiffy count of every CPU in seconds, guest time apart, and the counters as they are',
		gen.tuple(
			gen.array(gen.array(gen.int(0, 1000000000), { len: 10 }), { min_len: 1, max_len: 8 }),
			gen.int(0, 1 << 40), gen.int(0, 1 << 31)), (t) => {
			let cpus = t[0], ctxt = t[1], btime = t[2];
			let text = 'cpu  0 0 0 0 0 0 0 0 0 0\n';

			for (let i, times in cpus)
				text += `cpu${i} ${join(' ', times)}\n`;
			text += `intr ${ctxt} 0 1 2\nctxt ${ctxt}\nbtime ${btime}\n`;

			with_collector(cpu, stat(text), (r) => {
				let want = [];

				for (let i, times in cpus)
					for (let j = 0; j < 8; j++)
						push(want, `node_cpu_seconds_total{cpu="${i}",mode="${MODES[j]}"} ${times[j] / 100.0}`);
				for (let i, times in cpus)
					for (let j = 8; j < 10; j++)
						push(want, `node_cpu_guest_seconds_total{cpu="${i}",mode="${GUEST_MODES[j - 8]}"} ${times[j] / 100.0}`);
				push(want, `node_intr_total ${ctxt}`, `node_context_switches_total ${ctxt}`, `node_boot_time_seconds ${btime}`);

				assert.match(true, r.result.ok);
				assert.match(want, samples(r.lines));
			});
		});
});
