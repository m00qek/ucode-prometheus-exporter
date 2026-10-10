'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as pressure from 'prometheus.collectors.pressure';

// A kernel with CONFIG_PSI and CONFIG_IRQ_TIME_ACCOUNTING (made up: no device
// here has PSI; see test/fixtures/synthetic/SOURCES).
const PSI = fixtures.files('synthetic', [ '/proc/pressure/cpu', '/proc/pressure/io', '/proc/pressure/memory', '/proc/pressure/irq' ]);

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

function line(kind, total) {
	return `${kind} avg10=0.00 avg60=0.00 avg300=0.00 total=${total}\n`;
}

describe('collectors.pressure', () => {
	it("exports each resource's waiting and stalled time in seconds, as node_exporter", () => {
		with_collector(pressure, { fs: { data: PSI } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_pressure_cpu_waiting_seconds_total Total time in seconds that processes have waited for CPU time',
				'# TYPE node_pressure_cpu_waiting_seconds_total counter',
				'node_pressure_cpu_waiting_seconds_total 48.214379',
				'# HELP node_pressure_cpu_stalled_seconds_total Total time in seconds no process could make progress due to CPU congestion',
				'# TYPE node_pressure_cpu_stalled_seconds_total counter',
				'node_pressure_cpu_stalled_seconds_total 0',
				'# HELP node_pressure_io_waiting_seconds_total Total time in seconds that processes have waited due to IO congestion',
				'# TYPE node_pressure_io_waiting_seconds_total counter',
				'node_pressure_io_waiting_seconds_total 9.174312',
				'# HELP node_pressure_io_stalled_seconds_total Total time in seconds no process could make progress due to IO congestion',
				'# TYPE node_pressure_io_stalled_seconds_total counter',
				'node_pressure_io_stalled_seconds_total 6.608271',
				'# HELP node_pressure_memory_waiting_seconds_total Total time in seconds that processes have waited for memory',
				'# TYPE node_pressure_memory_waiting_seconds_total counter',
				'node_pressure_memory_waiting_seconds_total 0.315502',
				'# HELP node_pressure_memory_stalled_seconds_total Total time in seconds no process could make progress due to memory congestion',
				'# TYPE node_pressure_memory_stalled_seconds_total counter',
				'node_pressure_memory_stalled_seconds_total 0.21179',
				'# HELP node_pressure_irq_stalled_seconds_total Total time in seconds no process could make progress due to IRQ congestion',
				'# TYPE node_pressure_irq_stalled_seconds_total counter',
				'node_pressure_irq_stalled_seconds_total 27.750118',
			], r.lines);
		});
	});

	it("leaves out irq where the kernel has none, and cpu's full line before 5.13", () => {
		let data = {
			'/proc/pressure/cpu': line('some', 1000000),
			'/proc/pressure/io': PSI['/proc/pressure/io'],
			'/proc/pressure/memory': PSI['/proc/pressure/memory'],
			'/proc/pressure/irq': null,
		};

		with_collector(pressure, { fs: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_pressure_cpu_waiting_seconds_total 1',
				'node_pressure_io_waiting_seconds_total 9.174312',
				'node_pressure_io_stalled_seconds_total 6.608271',
				'node_pressure_memory_waiting_seconds_total 0.315502',
				'node_pressure_memory_stalled_seconds_total 0.21179',
			], samples(r.lines));
		});
	});

	it('has nothing to observe without /proc/pressure (no CONFIG_PSI, or psi=0)', () => {
		with_collector(pressure, { fs: { data: {}, behavior: { stat: () => null } } }, (r) => {
			assert.match({ ok: true, none: 'no PSI (no /proc/pressure: a kernel without CONFIG_PSI, or booted with psi=0)', error: null, lines: [], logs: [] },
				outcome(r));
		});
	});

	it('fails with SOURCE_UNREADABLE when cpu, io or memory cannot be read, keeping the others', () => {
		let data = { ...PSI, '/proc/pressure/io': null };

		with_collector(pressure, { fs: { data } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: '/proc/pressure/io' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match(5, length(samples(r.lines)));
		});
	});

	it('fails with SOURCE_INVALID for a line it cannot read, naming it', () => {
		let data = { ...PSI, '/proc/pressure/memory': 'some total=12\n' + line('full', 3) };

		with_collector(pressure, { fs: { data } }, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: '/proc/pressure/memory: "some total=12"' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it("fails with SOURCE_INVALID for a kind of line the resource has not, as irq's some", () => {
		let data = { ...PSI, '/proc/pressure/irq': line('some', 5) };

		with_collector(pressure, { fs: { data } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	prop('reports any total in microseconds in seconds', gen.int(0, 9007199254), (us) => {
		let data = { ...PSI, '/proc/pressure/cpu': line('some', us) + line('full', us) };

		with_collector(pressure, { fs: { data } }, (r) => {
			for (let f in filter(r.families, (f) => match(f.name, /^node_pressure_cpu_/))) {
				let delta = +f.samples[0].value * 1000000 - us;

				assert.match(true, delta > -0.5 && delta < 0.5, `${us} -> ${f.samples[0].value}`);
			}
		});
	});
});
