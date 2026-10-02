'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/selinux.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, proc } from 'prometheus_exporter.api';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'selinux',
	title: 'SELinux',
	help: 'Whether SELinux is enabled and enforcing, from /sys/fs/selinux/enforce.',
	needs: [ 'fs' ],
};

const ENFORCE = '/sys/fs/selinux/enforce';

// No selinuxfs means SELinux is off: that is a reading, not a failure.
export function collect(deps, out) {
	let mode = proc.first_line(deps.fs, ENFORCE);
	let enabled = out.gauge('node_selinux_enabled', 'SELinux is enabled, 1 is true, 0 is false');

	if (mode == null) {
		enabled(null, 0);
		return Result.ok();
	}

	enabled(null, 1);

	mode = trim(mode);
	if (!match(mode, COUNT))
		return Result.err(errors.SOURCE_INVALID, `${ENFORCE}: ${sprintf('%J', mode)}`);

	out.gauge('node_selinux_current_mode', 'Current SELinux enforcement mode')(null, mode);
	return Result.ok();
};
