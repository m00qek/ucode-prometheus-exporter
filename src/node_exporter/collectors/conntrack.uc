'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/conntrack.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'conntrack',
	help: 'The size of the connection tracking table, from /proc/sys/net/netfilter.',
	needs: [ 'fs' ],
};

const GAUGES = [
	[ '/proc/sys/net/netfilter/nf_conntrack_count', 'node_nf_conntrack_entries',
		'Number of currently allocated flow entries for connection tracking.' ],
	[ '/proc/sys/net/netfilter/nf_conntrack_max', 'node_nf_conntrack_entries_limit',
		'Maximum size of connection tracking table.' ],
];

// Neither file is there until nf_conntrack is loaded, as on an AP without a
// firewall. A base collector runs on every device, so a device without
// connection tracking succeeds with nothing to say, as the earlier ucode
// exporter did; one file without the other is an error.
export function collect(deps, out) {
	if (!length(filter(GAUGES, (g) => deps.fs.readfile(g[0]) != null)))
		return Result.ok();

	for (let g in GAUGES) {
		let line = first_line(deps.fs, g[0]);

		if (line == null)
			return Result.err(errors.SOURCE_UNREADABLE, g[0]);

		let v = trim(line);
		if (!match(v, /^[0-9]+$/))
			return Result.err(errors.SOURCE_INVALID, `${g[0]}: ${sprintf('%J', line)}`);

		out.gauge(g[1], g[2])(null, v);
	}

	return Result.ok();
};
