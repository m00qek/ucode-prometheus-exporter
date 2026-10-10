'use strict';

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

	let cpus = length(proc.fields(lines[0]));

	if (!cpus)
		return Result.err(errors.SOURCE_INVALID, `${INTERRUPTS}: no CPUs in its header`);

	let total = out.counter('node_interrupts_total', 'Interrupt details.');
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
