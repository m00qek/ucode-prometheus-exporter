'use strict';

// node_exporter's vmstat collector (collector/vmstat_linux.go): the fields of
// /proc/vmstat its --collector.vmstat.fields pattern matches, each as
// node_vmstat_<field>, untyped. The default pattern keeps page faults, paging
// and swapping, and oom_kill: on a router with little RAM and no swap, the OOM
// killer is how memory pressure ends, and nothing else counts its kills.
//
// The `fields` option is that pattern, a POSIX extended regular expression
// (ucode's, so RE2 syntax beyond ERE does not apply). Kernels built without
// CONFIG_VM_EVENT_COUNTERS, as on small targets, have no event fields: the
// default pattern then matches nothing, and the collector succeeds empty.

import { Result, errors, proc } from 'prometheus_exporter.api';

export const DEFAULT_FIELDS = '^(oom_kill|pgpg|pswp|pg.*fault).*';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
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

// Whether DEFAULT_FIELDS matches a field: it starts with oom_kill, pgpg or
// pswp, or with pg and has fault after. /proc/vmstat has 150 to 200 fields,
// and the default, which nearly every router has, is checked with a call or
// two of each rather than musl's regexec; any other pattern is matched.
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

	// node_exporter reads every value before it matches the name: a malformed
	// line fails the scrape, whatever the pattern. An integer as the format
	// spells it, as each of the kernel's is, needs no match.
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
