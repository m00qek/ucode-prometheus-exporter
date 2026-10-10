'use strict';

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'time',
	title: 'System time',
	help: 'The system clock, in seconds since the epoch.',
	needs: [ 'time' ],
};

export function collect(deps, out) {
	let now = deps.time.now();

	if (!(type(now) in [ 'int', 'double' ]))
		return Result.err(errors.SOURCE_INVALID, `clock: ${sprintf('%J', now)}`);

	out.gauge('node_time_seconds', 'System time in seconds since epoch (1970).')(null, now);
	return Result.ok();
};
