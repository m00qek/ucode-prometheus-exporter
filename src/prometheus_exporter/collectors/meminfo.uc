'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/meminfo.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, proc } from 'prometheus_exporter.api';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const LINE = /^([^:[:space:]]+):[[:space:]]+([0-9]+)([[:space:]]+kB)?[[:space:]]*$/;

export const meta = {
	name: 'meminfo',
	title: 'Memory',
	help: 'Memory statistics from /proc/meminfo.',
	needs: [ 'fs' ],
};

const PATH = '/proc/meminfo';
const PREFIX = 'node_memory_';

// { name, value } for a `Name:   value [kB]` line, or null, named as node_exporter's
// meminfo collector names it: a name's '(' becomes '_' and its ')' goes
// (Active(anon) is node_memory_Active_anon_bytes), and a field in kB is in
// bytes, with _bytes; a unitless one (the HugePages_* page counts) has no unit.
function parse(line) {
	let m = match(line, LINE);

	if (!m)
		return null;

	let name = m[1];

	// Nearly every name has no parenthesis: an index() rather than two replace().
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

	// A line it cannot read fails the collector, but not the fields after it.
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
