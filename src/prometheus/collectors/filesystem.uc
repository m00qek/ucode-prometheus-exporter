'use strict';

import { Result, errors, services, proc } from 'prometheus.exporter';

export const meta = {
	name: 'filesystem',
	title: 'Filesystems',
	help: 'Filesystem sizes, inodes and read-only flags, from the package\'s rpcd object (statvfs) and the host\'s /proc/mounts (rpcd\'s file read).',
	needs: [ 'ubus' ],
	ubus: { 'prometheus-exporter.filesystem': [ 'mounts' ], file: [ 'read' ], luci: [ 'getMountPoints' ] },
};

const MOUNTS = '/proc/mounts';

const EXCLUDED_MOUNT_POINTS = /^\/(dev|proc|run\/credentials|sys|var\/lib\/docker|var\/lib\/containers\/storage)(\/|$)/;
const EXCLUDED_FS_TYPES = [
	'autofs', 'binfmt_misc', 'bpf', 'cgroup', 'cgroup2', 'configfs', 'debugfs', 'devpts',
	'devtmpfs', 'fusectl', 'hugetlbfs', 'iso9660', 'mqueue', 'nsfs', 'overlay', 'proc',
	'procfs', 'pstore', 'rpc_pipefs', 'securityfs', 'selinuxfs', 'squashfs', 'sysfs', 'tracefs',
];

export function excluded(mount_point, fs_type) {
	return match(mount_point, EXCLUDED_MOUNT_POINTS) != null || fs_type in EXCLUDED_FS_TYPES;
};

export function unescape(field) {
	return replace(field, /\\([0-7][0-7][0-7])/g, (m, n) => chr(int(n, 8)));
};

function key(device, mount_point) {
	return device + '\n' + mount_point;
}

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
