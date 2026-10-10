'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'selinux',
	title: 'SELinux',
	help: 'Whether SELinux is enabled and enforcing, from /sys/fs/selinux/enforce and /proc/filesystems.',
	needs: [ 'fs' ],
};

const ENFORCE = '/sys/fs/selinux/enforce';
const FILESYSTEMS = '/proc/filesystems';

function has_selinuxfs(fs) {
	let lines = proc.lines(fs, FILESYSTEMS);

	if (lines == null)
		return null;

	for (let line in lines)
		if (proc.fields(line)[-1] == 'selinuxfs')
			return true;

	return false;
}

export function collect(deps, out) {
	let mode = proc.first_line(deps.fs, ENFORCE);
	let enabled = out.gauge('node_selinux_enabled', 'SELinux is enabled, 1 is true, 0 is false');

	if (mode == null) {
		let on = has_selinuxfs(deps.fs);

		if (on == null)
			return Result.err(errors.SOURCE_UNREADABLE, FILESYSTEMS);

		enabled(null, on);
		return Result.ok();
	}

	enabled(null, 1);

	mode = trim(mode);
	if (!match(mode, COUNT))
		return Result.err(errors.SOURCE_INVALID, `${ENFORCE}: ${sprintf('%J', mode)}`);

	out.gauge('node_selinux_current_mode', 'Current SELinux enforcement mode')(null, mode);
	return Result.ok();
};
