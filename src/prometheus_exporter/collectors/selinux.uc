'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/selinux.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// Whether SELinux is enabled, and its mode, from selinuxfs's enforce.
//
// The service's jail has a sysfs of its own (ujail -s), without what is
// mounted under the host's: selinuxfs at /sys/fs/selinux is never there, so
// enforce alone would read as SELinux off wherever SELinux is on. The kernel
// registers selinuxfs only when SELinux is enabled at boot (security/selinux/
// selinuxfs.c, init_sel_fs), and /proc/filesystems lists it whatever the
// mounts: without it, SELinux is off; with it and no enforce to read, SELinux
// is on, and its mode cannot be seen, so node_selinux_current_mode is left
// out. The jail does not mount /sys/fs/selinux for it: on a kernel without
// SELinux, as OpenWrt's are unless built for it, the path is not there, and
// the service would watch for it as long as it runs.

import { Result, errors, proc } from 'prometheus_exporter.api';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const COUNT = /^[0-9]+$/;

export const meta = {
	name: 'selinux',
	title: 'SELinux',
	help: 'Whether SELinux is enabled and enforcing, from /sys/fs/selinux/enforce and /proc/filesystems.',
	needs: [ 'fs' ],
};

const ENFORCE = '/sys/fs/selinux/enforce';
const FILESYSTEMS = '/proc/filesystems';

// Whether the kernel has selinuxfs: null when /proc/filesystems cannot be read.
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
