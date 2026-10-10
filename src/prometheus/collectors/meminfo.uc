'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

const LINE = /^([^:[:space:]]+):[[:space:]]+([0-9]+)([[:space:]]+kB)?[[:space:]]*$/;

export const meta = {
	name: 'meminfo',
	title: 'Memory',
	help: 'Memory statistics from /proc/meminfo.',
	needs: [ 'fs' ],
};

const PATH = '/proc/meminfo';
const PREFIX = 'node_memory_';

function parse(line) {
	let m = match(line, LINE);

	if (!m)
		return null;

	let name = m[1];

	if (index(name, '(') >= 0 || index(name, ')') >= 0)
		name = replace(replace(name, ')', ''), '(', '_');

	return m[3]
		? { name: `${PREFIX}${name}_bytes`, value: +m[2] * 1024 }
		: { name: `${PREFIX}${name}`, value: +m[2] };
}

export function collect(deps, out) {
	let l = proc.lines(deps.fs, PATH);

	if (l == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let bad = null;
	let rows = [];

	for (let line in l) {
		let f = parse(line);

		if (!f) {
			bad ??= line;
			continue;
		}

		push(rows, [ f.name, `Memory information field ${substr(f.name, length(PREFIX))}.`, f.value ]);
	}

	out.batch('gauge', rows);

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${sprintf('%J', bad)}`);
	if (!length(rows))
		return Result.err(errors.SOURCE_INVALID, `${PATH}: no fields`);

	return Result.ok();
};
