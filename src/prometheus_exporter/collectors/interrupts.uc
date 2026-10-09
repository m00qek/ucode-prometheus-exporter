'use strict';

// Interrupts per CPU, as node_exporter's interrupts collector
// (collector/interrupts_linux.go) counts them: each line of /proc/interrupts
// with a value for every CPU of its header is a counter
// node_interrupts_total{cpu, type, info, devices} per CPU, `cpu` the CPU's
// place in the header (0, 1, ...), `type` the line's name (a number, or a
// kind as NMI, LOC, IPI0). For a numbered one, `info` is the first word after
// the counts, its interrupt chip (GICv3, IO-APIC), and `devices` the rest:
// the chip's number, the trigger and the names of what handles it,
// "30 Level arch_timer". For any other, `info` is the rest, its description
// ("Rescheduling interrupts"), and `devices` empty. A line without a count
// for every CPU (ERR, MIS) is left out, as there. A line is split at its
// first ':', as node_exporter does for arm64's, which may have no blank after
// the name.
//
// node_exporter has it off by default: a series per interrupt and CPU,
// some 30 to 100 lines on a router times its CPUs, whose `devices` change
// when a driver is loaded again. Here it is a package of its own, in no
// group: installing it is turning it on.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'interrupts',
	title: 'Interrupts',
	help: 'Interrupts per CPU, from /proc/interrupts, as node_exporter\'s interrupts collector counts them.',
	needs: [ 'fs' ],
};

const INTERRUPTS = '/proc/interrupts';
const NUMBER = /^[0-9]+$/;

export function collect(deps, out) {
	let lines = proc.lines(deps.fs, INTERRUPTS);

	if (lines == null)
		return Result.err(errors.SOURCE_UNREADABLE, INTERRUPTS);

	// The header names a column per CPU: CPU0 CPU1 ...
	let cpus = length(proc.fields(lines[0]));

	if (!cpus)
		return Result.err(errors.SOURCE_INVALID, `${INTERRUPTS}: no CPUs in its header`);

	let total = out.counter('node_interrupts_total', 'Interrupt details.');
	// The cpu label of each column, made once: its place.
	let columns = [];
	for (let c = 0; c < cpus; c++)
		push(columns, `${c}`);

	for (let i = 1; i < length(lines); i++) {
		let colon = index(lines[i], ':');

		if (colon < 0)
			continue;

		let parts = proc.fields(substr(lines[i], colon + 1));

		if (length(parts) < cpus + 1)
			continue;

		let type = ltrim(substr(lines[i], 0, colon));
		let labels = match(type, NUMBER)
			? { cpu: null, type, info: parts[cpus], devices: join(' ', slice(parts, cpus + 1)) }
			: { cpu: null, type, info: join(' ', slice(parts, cpus)), devices: '' };

		for (let c = 0; c < cpus; c++) {
			labels.cpu = columns[c];
			total(labels, parts[c]);
		}
	}

	return Result.ok();
};
