'use strict';

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'selinux',
	help: 'Whether SELinux is enabled and enforcing, from /sys/fs/selinux/enforce.',
	needs: [ 'fs' ],
};

const ENFORCE = '/sys/fs/selinux/enforce';

// No selinuxfs means SELinux is off: that is a reading, not a failure.
export function collect(deps, out) {
	let mode = first_line(deps.fs, ENFORCE);
	let enabled = out.gauge('node_selinux_enabled', 'SELinux is enabled, 1 is true, 0 is false.');

	if (mode == null) {
		enabled(null, 0);
		return Result.ok();
	}

	enabled(null, 1);

	mode = trim(mode);
	if (!match(mode, /^[0-9]+$/))
		return Result.err(errors.SOURCE_INVALID, `${ENFORCE}: ${sprintf('%J', mode)}`);

	out.gauge('node_selinux_current_mode', 'Current SELinux enforcement mode, 1 for enforcing, 0 for permissive.')(null, mode);
	return Result.ok();
};
