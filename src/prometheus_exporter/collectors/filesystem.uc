'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/filesystem.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's filesystem collector: size, free and available bytes,
// inodes and free inodes, and the read-only flag of every mounted filesystem,
// less the pseudo and read-only image filesystems node_exporter leaves out (so
// / itself, an overlay, is not reported; /overlay under it is).
//
// OpenWrt 25.12's ucode has no statvfs(), and in the service's jail it would
// find the jail's mounts, not the host's: the sizes come from rpcd, which
// statvfs()es every mount in the host's /proc/mounts that has blocks, with
// luci-base's luci.core. luci's own `ubus call luci getMountPoints` reports no
// inode counts, so the package installs an rpcd plugin that is getMountPoints
// with them, `ubus call prometheus-exporter.filesystem mounts`
// (files/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc), whose
// node_filesystem_files and node_filesystem_files_free node_exporter has. Where
// rpcd has not loaded it yet (it is reloaded when the package is installed)
// the collector asks getMountPoints, and writes the sizes alone.
//
// The file system type and the read-only flag (the "ro" mount option, where the
// Lua collector read statvfs's ST_RDONLY) come from the host's mount table,
// which rpcd reads for it (`ubus call file read`, rpcd-mod-file, which
// luci-base depends on: the package depends on luci-base for both). Not from
// /proc/self/mounts: the service's jail has its own mount namespace, and its
// own PID namespace, so every mount table it can read is the jail's, which
// shares a mount or two with the host's at most, and has read-only flags of
// its own. rpcd reads a file that reports no size, as
// /proc/mounts does, in one read of at most 4 KiB, which the kernel ends at a
// whole line: on a system of more than about 60 mounts, those past it are left
// out.

import { Result, errors, services, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'filesystem',
	title: 'Filesystems',
	help: 'Filesystem sizes, inodes and read-only flags, from the package\'s rpcd object (statvfs) and the host\'s /proc/mounts (rpcd\'s file read).',
	needs: [ 'ubus' ],
	// Its package's rpcd plugin, and luci's, where rpcd has not loaded it.
	ubus: { 'prometheus-exporter.filesystem': [ 'mounts' ], file: [ 'read' ], luci: [ 'getMountPoints' ] },
};

const MOUNTS = '/proc/mounts';

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

// The host's mount table, as rpcd reads it: its lines, or the failed Result.
function host_mounts(ubus) {
	let res = ubus.call('file', 'read', { path: MOUNTS });

	if (!res.ok)
		return res;

	let data = res.data?.data;
	if (type(data) != 'string')
		return Result.err(errors.SOURCE_INVALID, `file read ${MOUNTS}: no data`);

	return Result.ok(split(data, '\n'));
}

export function collect(deps, out) {
	let mounts = host_mounts(deps.ubus);
	if (!mounts.ok)
		return mounts;

	let source = 'prometheus-exporter.filesystem mounts';
	let res = deps.ubus.call('prometheus-exporter.filesystem', 'mounts');

	if (!res.ok && services.object_missing(res)) {
		source = 'luci getMountPoints';
		res = deps.ubus.call('luci', 'getMountPoints');
	}

	if (!res.ok)
		return res;

	let points = res.data?.result;
	if (type(points) != 'array')
		return Result.err(errors.SOURCE_INVALID, `${source}: ${res.data?.error ?? 'no result'}`);

	let stats = {};
	for (let p in points)
		if (type(p) == 'object' && type(p.device) == 'string' && type(p.mount) == 'string')
			stats[key(p.device, p.mount)] ??= p;

	let size = out.gauge('node_filesystem_size_bytes', 'Filesystem size in bytes.');
	let free = out.gauge('node_filesystem_free_bytes', 'Filesystem free space in bytes.');
	let avail = out.gauge('node_filesystem_avail_bytes', 'Filesystem space available to non-root users in bytes.');
	let files = out.gauge('node_filesystem_files', 'Filesystem total file nodes.');
	let files_free = out.gauge('node_filesystem_files_free', 'Filesystem total free file nodes.');
	let readonly = out.gauge('node_filesystem_readonly', 'Filesystem read-only status.');
	let seen = {};

	for (let line in mounts.data) {
		let f = proc.fields(line);

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
		files(labels, st.files);
		files_free(labels, st.ffree);
		readonly(labels, 'ro' in split(f[3], ','));
	}

	return Result.ok();
};
