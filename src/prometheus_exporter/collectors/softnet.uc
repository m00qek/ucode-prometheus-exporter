'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'softnet',
	title: 'Network softirq statistics',
	help: 'Per-CPU network softirq statistics, from /proc/net/softnet_stat.',
	needs: [ 'fs' ],
};

export const PATH = '/proc/net/softnet_stat';

export const COLUMNS = [
	[ 0, 'processed_total', 'counter', 'Number of processed packets' ],
	[ 1, 'dropped_total', 'counter', 'Number of dropped packets' ],
	[ 2, 'times_squeezed_total', 'counter', 'Number of times processing packets ran out of quota' ],
	[ 8, 'cpu_collision_total', 'counter', 'Number of collision occur while obtaining device lock while transmitting' ],
	[ 9, 'received_rps_total', 'counter', 'Number of times cpu woken up received_rps' ],
	[ 10, 'flow_limit_count_total', 'counter', 'Number of times flow limit has been reached' ],
	[ 11, 'backlog_len', 'gauge', 'Softnet backlog status' ],
];

const CPU_COLUMN = 12;

const MIN_COLUMNS = 9;

const HEX = /^[0-9a-fA-F]+$/;

export function parse(rows) {
	let parsed = [];
	let seen = {};

	for (let i, line in rows) {
		let row = proc.fields(line);

		if (!length(row))
			continue;
		if (length(row) < MIN_COLUMNS)
			return `row ${i + 1}: ${length(row)} columns, fewer than ${MIN_COLUMNS}`;

		for (let v in row)
			if (!match(v, HEX))
				return `row ${i + 1}: ${sprintf('%J', v)} is not hex`;

		let values = map(row, (v) => hex(v));
		let cpu = length(row) > CPU_COLUMN ? values[CPU_COLUMN] : i;

		if (seen[cpu])
			return `row ${i + 1}: CPU ${cpu} again`;
		seen[cpu] = true;

		push(parsed, { cpu, values });
	}

	return length(parsed) ? parsed : 'no rows';
};

export function collect(deps, out) {
	let rows = proc.lines(deps.fs, PATH);

	if (rows == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let cpus = parse(rows);
	if (type(cpus) == 'string')
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${cpus}`);

	for (let c in COLUMNS) {
		let m = c[2] == 'counter'
			? out.counter(`node_softnet_${c[1]}`, c[3])
			: out.gauge(`node_softnet_${c[1]}`, c[3]);

		for (let cpu in cpus)
			if (c[0] < length(cpu.values))
				m({ cpu: '' + cpu.cpu }, cpu.values[c[0]]);
	}

	return Result.ok();
};
