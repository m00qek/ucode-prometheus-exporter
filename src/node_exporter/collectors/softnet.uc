'use strict';

// node_exporter's softnet collector (collector/softnet_linux.go, parsed as
// procfs's net_softnet.go does): per CPU, the packets its network softirq
// processed and dropped, and how often it ran out of budget. Dropped packets
// (a full backlog) and squeezes (time or budget ran out with work left) are
// what tells a router's CPU is the bottleneck, which no interface counter shows.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'softnet',
	title: 'Network softirq statistics',
	help: 'Per-CPU network softirq statistics, from /proc/net/softnet_stat.',
	needs: [ 'fs' ],
};

export const PATH = '/proc/net/softnet_stat';

// [ column, name, type, help ]: node_exporter's metrics and the columns
// softnet_seq_show() (net/core/net-procfs.c) writes them in. Today's kernels
// write 0 where cpu_collision was, but node_exporter still has it.
export const COLUMNS = [
	[ 0, 'processed_total', 'counter', 'Number of processed packets' ],
	[ 1, 'dropped_total', 'counter', 'Number of dropped packets' ],
	[ 2, 'times_squeezed_total', 'counter', 'Number of times processing packets ran out of quota' ],
	[ 8, 'cpu_collision_total', 'counter', 'Number of collision occur while obtaining device lock while transmitting' ],
	[ 9, 'received_rps_total', 'counter', 'Number of times cpu woken up received_rps' ],
	[ 10, 'flow_limit_count_total', 'counter', 'Number of times flow limit has been reached' ],
	[ 11, 'backlog_len', 'gauge', 'Softnet backlog status' ],
];

// The column with the CPU's number, since Linux 5.14: a row per online CPU, so
// with CPUs offline the row number is not the CPU's. Before, the row number is
// all there is, as procfs takes it.
const CPU_COLUMN = 12;

// procfs refuses fewer columns: Linux 2.6.23 already wrote nine.
const MIN_COLUMNS = 9;

const HEX = /^[0-9a-fA-F]+$/;

// The rows as { cpu, values } with values by column, or a string saying what is
// wrong with the table.
export function parse(rows) {
	let parsed = [];
	let seen = {};

	for (let i, line in rows) {
		let row = fields(line);

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

// A metric whose column an older kernel does not write is left out for it,
// where node_exporter writes 0.
export function collect(deps, out) {
	let rows = lines(deps.fs, PATH);

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
