'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

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

	let x = proc.fields(line);
	if (length(x) < 3 || !match(x[0], AVERAGE) || !match(x[1], AVERAGE) || !match(x[2], AVERAGE))
		return Result.err(errors.SOURCE_INVALID, `/proc/loadavg: ${sprintf('%J', line)}`);

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	out.gauge('node_load5', '5m load average.')(null, x[1]);
	out.gauge('node_load15', '15m load average.')(null, x[2]);

	return Result.ok();
};
