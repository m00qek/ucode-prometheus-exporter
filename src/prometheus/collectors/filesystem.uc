'use strict';

import { Result, errors, services } from 'prometheus.exporter';

export const meta = {
	name: 'filesystem',
	title: 'Filesystems',
	help: 'Filesystem sizes, inodes and read-only flags of the host\'s mounts, from the package\'s rpcd object (statvfs).',
	needs: [ 'ubus' ],
	ubus: { 'prometheus-exporter.filesystem': [ 'mounts' ] },
};

const OBJECT = 'prometheus-exporter.filesystem';

const EXCLUDED_MOUNT_POINTS = /^\/(dev|proc|run\/credentials|sys|var\/lib\/docker|var\/lib\/containers\/storage)(\/|$)/;
const EXCLUDED_FS_TYPES = [
	'autofs', 'binfmt_misc', 'bpf', 'cgroup', 'cgroup2', 'configfs', 'debugfs', 'devpts',
	'devtmpfs', 'fusectl', 'hugetlbfs', 'iso9660', 'mqueue', 'nsfs', 'overlay', 'proc',
	'procfs', 'pstore', 'rpc_pipefs', 'securityfs', 'selinuxfs', 'squashfs', 'sysfs', 'tracefs',
];

export function excluded(mount_point, fs_type) {
	return match(mount_point, EXCLUDED_MOUNT_POINTS) != null || fs_type in EXCLUDED_FS_TYPES;
};

export function collect(deps, out) {
	let res = deps.ubus.call(OBJECT, 'mounts');

	if (services.object_missing(res))
		return Result.err(errors.UBUS_CALL_FAILED, `${OBJECT} mounts: ${res.data.status}: rpcd has not loaded the package's plugin; /etc/init.d/rpcd reload loads it`);
	if (!res.ok)
		return res;

	let points = res.data?.result;
	if (type(points) != 'array')
		return Result.err(errors.SOURCE_INVALID, `${OBJECT} mounts: ${res.data?.error ?? 'no result'}`);

	let size = out.gauge('node_filesystem_size_bytes', 'Filesystem size in bytes.');
	let free = out.gauge('node_filesystem_free_bytes', 'Filesystem free space in bytes.');
	let avail = out.gauge('node_filesystem_avail_bytes', 'Filesystem space available to non-root users in bytes.');
	let files = out.gauge('node_filesystem_files', 'Filesystem total file nodes.');
	let files_free = out.gauge('node_filesystem_files_free', 'Filesystem total free file nodes.');
	let readonly = out.gauge('node_filesystem_readonly', 'Filesystem read-only status.');
	let seen = {};

	for (let p in points) {
		if (type(p) != 'object' || type(p.device) != 'string' || type(p.mount) != 'string' || type(p.fstype) != 'string')
			continue;

		let labels = { device: p.device, fstype: p.fstype, mountpoint: p.mount };
		let id = sprintf('%J', labels);

		if (excluded(p.mount, p.fstype) || seen[id])
			continue;

		seen[id] = true;
		size(labels, p.size);
		free(labels, p.free);
		avail(labels, p.avail);
		files(labels, p.files);
		files_free(labels, p.ffree);
		readonly(labels, p.ro === true);
	}

	return Result.ok();
};
