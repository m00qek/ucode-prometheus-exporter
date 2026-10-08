'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/loadavg.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, proc } from 'prometheus_exporter.api';

// An average as the kernel writes it ("%lu.%02lu", fs/proc/loadavg.c).
// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const AVERAGE = /^[0-9]+(\.[0-9]+)?$/;

export const meta = {
	name: 'loadavg',
	title: 'Load average',
	help: 'Load averages from /proc/loadavg.',
	needs: [ 'fs' ],
};

export function collect(deps, out) {
	let line = proc.first_line(deps.fs, '/proc/loadavg');

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, '/proc/loadavg');

	// Three averages, or nothing written: one that is not a number would be
	// left out, and the collector would succeed without it.
	let x = proc.fields(line);
	if (length(x) < 3 || !match(x[0], AVERAGE) || !match(x[1], AVERAGE) || !match(x[2], AVERAGE))
		return Result.err(errors.SOURCE_INVALID, `/proc/loadavg: ${sprintf('%J', line)}`);

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	out.gauge('node_load5', '5m load average.')(null, x[1]);
	out.gauge('node_load15', '15m load average.')(null, x[2]);

	return Result.ok();
};
