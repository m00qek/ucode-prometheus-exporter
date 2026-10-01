'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/cpu.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { lines, fields } from 'prometheus_exporter.proc';

export const meta = {
	name: 'cpu',
	title: 'CPU',
	help: 'CPU times, interrupts, context switches and processes from /proc/stat.',
	needs: [ 'fs' ],
};

const PATH = '/proc/stat';

// The columns of a cpuN line, in the kernel's order (Documentation/filesystems/proc.rst).
// The last two, guest and guest_nice, are node_cpu_guest_seconds_total's user and
// nice modes, as node_exporter's cpu collector (collector/cpu_linux.go) has them.
const MODES = [ 'user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal', 'user', 'nice' ];
const GUEST = 8;

// The one-value lines: [ type, name, help ], as node_exporter's stat collector
// (collector/stat_linux.go) names them.
const SCALARS = {
	intr: [ 'counter', 'node_intr_total', 'Total number of interrupts serviced.' ],
	ctxt: [ 'counter', 'node_context_switches_total', 'Total number of context switches.' ],
	btime: [ 'gauge', 'node_boot_time_seconds', 'Node boot time, in unixtime.' ],
	processes: [ 'counter', 'node_forks_total', 'Total number of forks.' ],
	procs_running: [ 'gauge', 'node_procs_running', 'Number of processes in runnable state.' ],
	procs_blocked: [ 'gauge', 'node_procs_blocked', 'Number of processes blocked waiting for I/O to complete.' ],
};

// USER_HZ, the unit of the times: 100 on every architecture OpenWrt runs on.
const USER_HZ = 100.0;

function is_count(s) {
	return match(s, /^[0-9]+$/) != null;
}

export function collect(deps, out) {
	let l = lines(deps.fs, PATH);

	if (l == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let cpus = [];
	let scalars = [];

	// The `cpu` line sums the others, so only the cpuN lines are exported.
	for (let line in l) {
		let x = fields(line);

		if (match(x[0], /^cpu[0-9]+$/)) {
			let times = slice(x, 1, 1 + length(MODES));

			if (!length(times) || length(filter(times, is_count)) != length(times))
				return Result.err(errors.SOURCE_INVALID, `${PATH}: ${sprintf('%J', line)}`);

			push(cpus, [ substr(x[0], 3), times ]);
		} else if (SCALARS[x[0]] && length(x) >= 2) {
			push(scalars, x);
		}
	}

	if (!length(cpus))
		return Result.err(errors.SOURCE_INVALID, `${PATH}: no cpu lines`);

	// The cpu label is the CPU's number, as node_exporter's.
	let seconds = out.counter('node_cpu_seconds_total', 'Seconds the CPUs spent in each mode.');
	for (let cpu in cpus)
		for (let i = 0; i < GUEST && i < length(cpu[1]); i++)
			seconds({ cpu: cpu[0], mode: MODES[i] }, cpu[1][i] / USER_HZ);

	let guest = out.counter('node_cpu_guest_seconds_total', 'Seconds the CPUs spent in guests (VMs) for each mode.');
	for (let cpu in cpus)
		for (let i = GUEST; i < length(cpu[1]); i++)
			guest({ cpu: cpu[0], mode: MODES[i] }, cpu[1][i] / USER_HZ);

	for (let x in scalars) {
		let s = SCALARS[x[0]];
		out[s[0]](s[1], s[2])(null, x[1]);
	}

	return Result.ok();
};
