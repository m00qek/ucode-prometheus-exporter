'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/filesystem.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

// The Lua exporter's filesystem collector: size, free and available bytes and
// the read-only flag of every mounted filesystem, less the pseudo and read-only
// image filesystems node_exporter leaves out (so / itself, an overlay, is not
// reported; /overlay under it is).
//
// OpenWrt 25.12's ucode has no statvfs(), so the sizes come from luci-base's
// `ubus call luci getMountPoints`, which statvfs()es every mount in /proc/mounts
// that has blocks. That call reports no inode counts, so node_filesystem_files
// and node_filesystem_files_free, which the Lua collector has, are left out.
// The file system type and the read-only flag (the "ro" mount option, where the
// Lua collector read statvfs's ST_RDONLY) come from /proc/self/mounts.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { lines, fields } from 'node_exporter.proc';

export const meta = {
	name: 'filesystem',
	help: 'Filesystem sizes and read-only flags, from luci getMountPoints and /proc/self/mounts.',
	needs: [ 'fs', 'ubus' ],
};

const MOUNTS = '/proc/self/mounts';

// node_exporter's defaults (collector/filesystem_linux.go), as the Lua collector has them.
const EXCLUDED_MOUNT_POINTS = /^\/(dev|proc|run\/credentials|sys|var\/lib\/docker|var\/lib\/containers\/storage)(\/|$)/;
const EXCLUDED_FS_TYPES = [
	'autofs', 'binfmt_misc', 'bpf', 'cgroup', 'cgroup2', 'configfs', 'debugfs', 'devpts',
	'devtmpfs', 'fusectl', 'hugetlbfs', 'iso9660', 'mqueue', 'nsfs', 'overlay', 'proc',
	'procfs', 'pstore', 'rpc_pipefs', 'securityfs', 'selinuxfs', 'squashfs', 'sysfs', 'tracefs',
];

// Whether a mount is one node_exporter leaves out.
export function excluded(mount_point, fs_type) {
	return match(mount_point, EXCLUDED_MOUNT_POINTS) != null || fs_type in EXCLUDED_FS_TYPES;
};

// A /proc/mounts field with its octal escapes (\040 for a space) undone, as
// getMountPoints reports device and mount point.
export function unescape(field) {
	return replace(field, /\\([0-7][0-7][0-7])/g, (m, n) => chr(int(n, 8)));
};

function key(device, mount_point) {
	return device + '\n' + mount_point;
}

export function collect(deps, out) {
	let mounts = lines(deps.fs, MOUNTS);

	if (mounts == null)
		return Result.err(errors.SOURCE_UNREADABLE, MOUNTS);

	let res = deps.ubus.call('luci', 'getMountPoints');
	if (!res.ok)
		return res;

	let points = res.data?.result;
	if (type(points) != 'array')
		return Result.err(errors.SOURCE_INVALID, `luci getMountPoints: ${res.data?.error ?? 'no result'}`);

	let stats = {};
	for (let p in points)
		if (type(p) == 'object' && type(p.device) == 'string' && type(p.mount) == 'string')
			stats[key(p.device, p.mount)] ??= p;

	let size = out.gauge('node_filesystem_size_bytes', 'Filesystem size in bytes.');
	let free = out.gauge('node_filesystem_free_bytes', 'Filesystem free space in bytes.');
	let avail = out.gauge('node_filesystem_avail_bytes', 'Filesystem space available to non-root users in bytes.');
	let readonly = out.gauge('node_filesystem_readonly', 'Filesystem read-only status.');
	let seen = {};

	for (let line in mounts) {
		let f = fields(line);

		if (length(f) < 4)
			continue;

		let device = unescape(f[0]), mountpoint = unescape(f[1]), fstype = f[2];
		let st = stats[key(device, mountpoint)];
		let labels = { device, fstype, mountpoint };
		let id = sprintf('%J', labels);

		// A mount statvfs() could not read, or one without blocks, is not in the reply.
		if (excluded(mountpoint, fstype) || !st || seen[id])
			continue;

		seen[id] = true;
		size(labels, st.size);
		free(labels, st.free);
		avail(labels, st.avail);
		readonly(labels, 'ro' in split(f[3], ','));
	}

	return Result.ok();
};
