'use strict';

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'time',
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
