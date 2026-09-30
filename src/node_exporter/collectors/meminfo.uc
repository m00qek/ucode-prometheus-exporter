'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/meminfo.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines } from 'node_exporter.proc';

export const meta = {
	name: 'meminfo',
	help: 'Memory statistics from /proc/meminfo.',
	needs: [ 'fs' ],
};

const PATH = '/proc/meminfo';
const PREFIX = 'node_memory_';

// { name, value } for a `Name:   value [kB]` line, or null. A name's '(' becomes
// '_' and its ')' goes, as upstream: Active(anon) is node_memory_Active_anon_bytes.
// Every field is _bytes, the unitless HugePages_* counts too, as both upstream
// exporters name them.
function parse(line) {
	let m = match(line, /^([^:[:space:]]+):[[:space:]]+([0-9]+)([[:space:]]+kB)?[[:space:]]*$/);

	if (!m)
		return null;

	let name = replace(replace(m[1], ')', ''), '(', '_');
	return { name: `${PREFIX}${name}_bytes`, value: m[3] ? +m[2] * 1024 : +m[2] };
}

export function collect(deps, out) {
	let l = lines(deps.fs, PATH);

	if (l == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let bad = null;
	let n = 0;

	// A line it cannot read fails the collector, but not the fields after it.
	for (let line in l) {
		let f = parse(line);

		if (!f) {
			bad ??= line;
			continue;
		}

		out.gauge(f.name, `Memory information field ${substr(f.name, length(PREFIX))}.`)(null, f.value);
		n++;
	}

	if (bad != null)
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${sprintf('%J', bad)}`);
	if (!n)
		return Result.err(errors.SOURCE_INVALID, `${PATH}: no fields`);

	return Result.ok();
};
