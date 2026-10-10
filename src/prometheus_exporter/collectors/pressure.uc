'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'pressure',
	title: 'Pressure stall information',
	help: 'Time tasks waited for or were stalled on CPU, I/O, memory and IRQs, from /proc/pressure.',
	needs: [ 'fs' ],
};

const ROOT = '/proc/pressure';

const LINE = /^(some|full) avg10=[0-9.]+ avg60=[0-9.]+ avg300=[0-9.]+ total=([0-9]+)$/;

const RESOURCES = [
	[ 'cpu', false, {
		some: [ 'node_pressure_cpu_waiting_seconds_total', 'Total time in seconds that processes have waited for CPU time' ],
		full: [ 'node_pressure_cpu_stalled_seconds_total', 'Total time in seconds no process could make progress due to CPU congestion' ],
	} ],
	[ 'io', false, {
		some: [ 'node_pressure_io_waiting_seconds_total', 'Total time in seconds that processes have waited due to IO congestion' ],
		full: [ 'node_pressure_io_stalled_seconds_total', 'Total time in seconds no process could make progress due to IO congestion' ],
	} ],
	[ 'memory', false, {
		some: [ 'node_pressure_memory_waiting_seconds_total', 'Total time in seconds that processes have waited for memory' ],
		full: [ 'node_pressure_memory_stalled_seconds_total', 'Total time in seconds no process could make progress due to memory congestion' ],
	} ],
	[ 'irq', true, {
		full: [ 'node_pressure_irq_stalled_seconds_total', 'Total time in seconds no process could make progress due to IRQ congestion' ],
	} ],
];

export function collect(deps, out) {
	if (deps.fs.stat(ROOT) == null)
		return Result.none('no PSI (no /proc/pressure: a kernel without CONFIG_PSI, or booted with psi=0)');

	let unreadable = [], invalid = [];

	for (let r in RESOURCES) {
		let path = `${ROOT}/${r[0]}`;
		let lines = proc.lines(deps.fs, path);

		if (lines == null) {
			if (!r[1])
				push(unreadable, path);
			continue;
		}

		for (let line in lines) {
			if (line == '')
				continue;

			let m = match(line, LINE);
			let f = m ? r[2][m[1]] : null;

			if (!f) {
				push(invalid, `${path}: ${sprintf('%J', line)}`);
				continue;
			}

			out.counter(f[0], f[1])(null, int(m[2]) / 1000000.0);
		}
	}

	if (length(unreadable))
		return Result.err(errors.SOURCE_UNREADABLE, join(', ', unreadable));
	if (length(invalid))
		return Result.err(errors.SOURCE_INVALID, join('; ', invalid));

	return Result.ok();
};
