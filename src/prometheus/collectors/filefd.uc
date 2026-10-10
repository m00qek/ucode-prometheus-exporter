'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'filefd',
	title: 'File descriptors',
	help: 'File descriptors allocated and the most there may be, from /proc/sys/fs/file-nr.',
	needs: [ 'fs' ],
};

const PATH = '/proc/sys/fs/file-nr';

export function collect(deps, out) {
	let line = proc.first_line(deps.fs, PATH);

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let x = proc.fields(line);
	if (length(x) < 3 || length(filter(slice(x, 0, 3), (v) => !match(v, COUNT))))
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${sprintf('%J', line)}`);

	out.gauge('node_filefd_allocated', 'File descriptor statistics: allocated.')(null, x[0]);
	out.gauge('node_filefd_maximum', 'File descriptor statistics: maximum.')(null, x[2]);

	return Result.ok();
};
