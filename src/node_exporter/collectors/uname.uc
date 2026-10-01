'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/uname.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'uname',
	title: 'Kernel and host names',
	help: 'The kernel and host names uname reports, from /proc/sys/kernel.',
	needs: [ 'fs' ],
};

// [ label, file in /proc/sys/kernel ], in label order. The machine is the
// kernel's own utsname machine (what `uname -m` prints), so no program is run.
const FIELDS = [
	[ 'sysname', 'ostype' ],
	[ 'nodename', 'hostname' ],
	[ 'release', 'osrelease' ],
	[ 'version', 'version' ],
	[ 'machine', 'arch' ],
	[ 'domainname', 'domainname' ],
];

// A file that cannot be read leaves its label out and fails the collector,
// after the sample is recorded with the labels that could.
export function collect(deps, out) {
	let labels = {};
	let missing = [];

	for (let f in FIELDS) {
		let path = `/proc/sys/kernel/${f[1]}`;
		let value = first_line(deps.fs, path);

		if (value == null)
			push(missing, path);

		labels[f[0]] = value;
	}

	if (length(missing) == length(FIELDS))
		return Result.err(errors.SOURCE_UNREADABLE, join(' ', missing));

	out.gauge('node_uname_info', 'Labeled system information as provided by the uname system call.')(labels, 1);

	return length(missing)
		? Result.err(errors.SOURCE_UNREADABLE, join(' ', missing))
		: Result.ok();
};
