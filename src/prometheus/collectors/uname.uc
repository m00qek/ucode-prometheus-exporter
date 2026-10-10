'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const meta = {
	name: 'uname',
	title: 'Kernel and host names',
	help: 'The kernel and host names uname reports, from /proc/sys/kernel.',
	needs: [ 'fs' ],
};

const FIELDS = [
	[ 'sysname', 'ostype' ],
	[ 'nodename', 'hostname' ],
	[ 'release', 'osrelease' ],
	[ 'version', 'version' ],
	[ 'machine', 'arch' ],
	[ 'domainname', 'domainname' ],
];

export function collect(deps, out) {
	let labels = {};
	let missing = [];

	for (let f in FIELDS) {
		let path = `/proc/sys/kernel/${f[1]}`;
		let value = proc.first_line(deps.fs, path);

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
