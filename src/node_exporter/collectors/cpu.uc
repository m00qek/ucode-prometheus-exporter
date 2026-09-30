'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/cpu.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'cpu',
	help: 'CPU times, interrupts, context switches and processes from /proc/stat.',
	needs: [ 'fs' ],
};

const PATH = '/proc/stat';

// The columns of a cpuN line, in the kernel's order (Documentation/filesystems/proc.rst).
const MODES = [ 'user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal', 'guest', 'guest_nice' ];

// The one-value lines: [ type, name, help ], named as the upstream ucode exporter does.
const SCALARS = {
	intr: [ 'counter', 'node_intr_total', 'Total number of interrupts serviced.' ],
	ctxt: [ 'counter', 'node_context_switches_total', 'Total number of context switches.' ],
	btime: [ 'gauge', 'node_boot_time_seconds', 'Node boot time, in unixtime.' ],
	processes: [ 'counter', 'node_forks_total', 'Total number of forks.' ],
	procs_running: [ 'gauge', 'node_procs_running_total', 'Number of processes in runnable state.' ],
	procs_blocked: [ 'gauge', 'node_procs_blocked_total', 'Number of processes blocked waiting for I/O to complete.' ],
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

			push(cpus, [ x[0], times ]);
		} else if (SCALARS[x[0]] && length(x) >= 2) {
			push(scalars, x);
		}
	}

	if (!length(cpus))
		return Result.err(errors.SOURCE_INVALID, `${PATH}: no cpu lines`);

	let seconds = out.counter('node_cpu_seconds_total', 'Seconds the CPUs spent in each mode.');
	for (let cpu in cpus)
		for (let i, t in cpu[1])
			seconds({ cpu: cpu[0], mode: MODES[i] }, t / USER_HZ);

	for (let x in scalars) {
		let s = SCALARS[x[0]];
		out[s[0]](s[1], s[2])(null, x[1]);
	}

	return Result.ok();
};
