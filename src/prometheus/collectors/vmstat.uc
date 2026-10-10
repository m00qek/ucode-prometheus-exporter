'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const DEFAULT_FIELDS = '^(oom_kill|pgpg|pswp|pg.*fault).*';

const INTEGER = /^-?[0-9]+$/;

export const meta = {
	name: 'vmstat',
	title: 'Virtual memory statistics',
	help: 'Virtual memory statistics, from /proc/vmstat.',
	needs: [ 'fs' ],
	options: {
		fields: { default: DEFAULT_FIELDS, title: 'Exported fields', datatype: 'regex', help: 'A regular expression of the /proc/vmstat fields to export.' },
	},
};

export const PATH = '/proc/vmstat';

function default_field(name) {
	let p = substr(name, 0, 4);

	return p == 'pgpg' || p == 'pswp' || (p == 'oom_' && substr(name, 0, 8) == 'oom_kill') ||
		(substr(p, 0, 2) == 'pg' && index(name, 'fault') >= 2);
}

export function collect(deps, out, options) {
	let pattern = null;

	try {
		if (options.fields != DEFAULT_FIELDS)
			pattern = regexp(options.fields);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `fields: ${e.message}`);
	}

	let rows = proc.rows(deps.fs, PATH);
	if (rows == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let matched = [];
	for (let i, f in rows) {
		if (!length(f))
			continue;
		if (length(f) != 2 || (('' + +f[1]) != f[1] && !match(f[1], INTEGER)))
			return Result.err(errors.SOURCE_INVALID, `${PATH}: line ${i + 1}: ${sprintf('%J', join(' ', f))}`);

		if (pattern ? match(f[0], pattern) : default_field(f[0]))
			push(matched, [ `node_vmstat_${f[0]}`, `/proc/vmstat information field ${f[0]}.`, f[1] ]);
	}

	out.batch('untyped', matched);

	return Result.ok();
};
