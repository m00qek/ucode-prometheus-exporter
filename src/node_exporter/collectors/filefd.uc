'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/filefd.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { first_line, fields } from 'node_exporter.proc';

export const meta = {
	name: 'filefd',
	help: 'File descriptors allocated and the most there may be, from /proc/sys/fs/file-nr.',
	needs: [ 'fs' ],
};

const PATH = '/proc/sys/fs/file-nr';

// `allocated  free  maximum`; free has been 0 since Linux 2.6.
export function collect(deps, out) {
	let line = first_line(deps.fs, PATH);

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, PATH);

	let x = fields(line);
	if (length(x) < 3 || length(filter(slice(x, 0, 3), (v) => !match(v, /^[0-9]+$/))))
		return Result.err(errors.SOURCE_INVALID, `${PATH}: ${sprintf('%J', line)}`);

	out.gauge('node_filefd_allocated', 'File descriptor statistics: allocated.')(null, x[0]);
	out.gauge('node_filefd_maximum', 'File descriptor statistics: maximum.')(null, x[2]);

	return Result.ok();
};
