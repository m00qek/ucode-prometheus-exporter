'use strict';

// Pressure stall information (PSI), as node_exporter's pressure collector
// (collector/pressure_linux.go) has it: of each resource of /proc/pressure,
// the time some task waited for it (the `some` line's total) and, where the
// kernel writes a `full` line, the time every non-idle task was stalled on
// it at once, both counters in seconds where the kernel counts microseconds.
// cpu, io and memory are each two families, irq one (the kernel has only a
// `full` line of it, and only with CONFIG_IRQ_TIME_ACCOUNTING, since 6.1):
//
//   node_pressure_cpu_waiting_seconds_total     cpu's some
//   node_pressure_cpu_stalled_seconds_total     cpu's full (5.13 and later)
//   node_pressure_io_waiting_seconds_total      io's some
//   node_pressure_io_stalled_seconds_total      io's full
//   node_pressure_memory_waiting_seconds_total  memory's some
//   node_pressure_memory_stalled_seconds_total  memory's full
//   node_pressure_irq_stalled_seconds_total     irq's full
//
// The averages of each line (avg10, avg60, avg300) are left out, as there:
// rate() of a total gives any window.
//
// A kernel without CONFIG_PSI, or one booted with psi=0, has no
// /proc/pressure: nothing to observe, as node_exporter finds no data there.
// With it, cpu, io and memory are always there: one that cannot be read
// fails the collector, as does a line that is not "<some|full> ...
// total=<n>". irq is read where it is there.
//
// node_exporter has it on by default, but OpenWrt's kernels leave CONFIG_PSI
// off: in the base package it would cost every scrape for nothing. Here it
// is a package of its own, in no group: installing it is turning it on.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'pressure',
	title: 'Pressure stall information',
	help: 'Time tasks waited for or were stalled on CPU, I/O, memory and IRQs, from /proc/pressure.',
	needs: [ 'fs' ],
};

const ROOT = '/proc/pressure';

// <some|full> avg10=<n> avg60=<n> avg300=<n> total=<microseconds>
const LINE = /^(some|full) avg10=[0-9.]+ avg60=[0-9.]+ avg300=[0-9.]+ total=([0-9]+)$/;

// Each resource, in node_exporter's order: [ resource, optional, the families
// of its lines by kind: [ name, help ] ], node_exporter's names and help.
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
