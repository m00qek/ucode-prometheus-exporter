'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/loadavg.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, proc } from 'prometheus_exporter.api';

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
	if (length(x) < 3)
		return Result.err(errors.SOURCE_INVALID, `/proc/loadavg: ${sprintf('%J', line)}`);

	out.gauge('node_load1', '1m load average.')(null, x[0]);
	out.gauge('node_load5', '5m load average.')(null, x[1]);
	out.gauge('node_load15', '15m load average.')(null, x[2]);

	return Result.ok();
};
