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

export function collect(deps, out, options) {
	let pattern;

	try {
		pattern = regexp(options.fields);
	} catch (e) {
		return Result.err(errors.CONFIG_INVALID, `fields: ${e.message}`);
	}

	let rows = proc.lines(deps.fs, PATH);
	if (rows == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	// node_exporter reads every value before it matches the name: a malformed
	// line fails the scrape, whatever the pattern.
	let matched = [];
	for (let i, line in rows) {
		let f = proc.fields(line);

		if (!length(f))
			continue;
		if (length(f) != 2 || !match(f[1], INTEGER))
			return Result.err(errors.SOURCE_INVALID, `${PATH}: line ${i + 1}: ${sprintf('%J', line)}`);

		if (match(f[0], pattern))
			push(matched, f);
	}

	for (let f in matched)
		out.untyped(`node_vmstat_${f[0]}`, `/proc/vmstat information field ${f[0]}.`)(null, f[1]);

	return Result.ok();
};
