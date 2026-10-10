'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'entropy',
	title: 'Kernel entropy',
	help: 'The entropy available to the kernel random number generator, from /proc/sys/kernel/random.',
	needs: [ 'fs' ],
};

const GAUGES = [
	[ '/proc/sys/kernel/random/entropy_avail', 'node_entropy_available_bits', 'Bits of available entropy.' ],
	[ '/proc/sys/kernel/random/poolsize', 'node_entropy_pool_size_bits', 'Bits of entropy pool.' ],
];

export function collect(deps, out) {
	for (let g in GAUGES) {
		let line = proc.first_line(deps.fs, g[0]);

		if (line == null)
			return Result.err(errors.SOURCE_UNREADABLE, g[0]);

		let v = trim(line);
		if (!match(v, COUNT))
			return Result.err(errors.SOURCE_INVALID, `${g[0]}: ${sprintf('%J', line)}`);

		out.gauge(g[1], g[2])(null, v);
	}

	return Result.ok();
};
