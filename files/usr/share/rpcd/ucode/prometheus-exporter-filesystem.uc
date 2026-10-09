'use strict';

// rpcd ucode plugin of ucode-prometheus-exporter-filesystem: the sizes and
// inode counts of the host's mounts, for the filesystem collector, which the
// service's jail keeps from the host's mount table and from statvfs() of it.
// ucode's fs module has no statvfs(); luci-base's luci.core has, which luci's
// own getMountPoints calls, and this is getMountPoints with the inode counts
// it leaves out: of each mount of /proc/mounts whose statvfs() has blocks,
// its device and mount point (octal escapes undone), its size, free and
// available bytes, and its inodes and free inodes.
//
//   ubus call prometheus-exporter.filesystem mounts
//   { "result": [ { "device": "/dev/root", "mount": "/rom", "size": ...,
//     "free": ..., "avail": ..., "files": ..., "ffree": ... }, ... ] }
//
// Modules are required when the method is called, not when rpcd loads the
// plugin: a luci-base without luci.core fails the call, and leaves rpcd and
// its other objects as they are.

const MOUNTS = '/proc/mounts';

// A /proc/mounts field with its octal escapes (\040 for a space) undone.
function unescape(field) {
	return replace(field, /\\([0-7][0-7][0-7])/g, (m, n) => chr(int(n, 8)));
}

// The mounts of `fs`'s /proc/mounts that statvfs() finds blocks in.
function mounts(fs, statvfs) {
	let f = fs.open(MOUNTS, 'r');

	if (!f)
		return { error: `${MOUNTS}: ${fs.error()}` };

	let result = [];

	for (let line = f.read('line'); length(line); line = f.read('line')) {
		let m = split(line, ' ');
		let mount = unescape(m[1] ?? '');
		let st = (mount != '') ? statvfs(mount) : null;

		if (st?.blocks > 0)
			push(result, {
				device: unescape(m[0]), mount,
				size: st.bsize * st.blocks, free: st.bsize * st.bfree, avail: st.bsize * st.bavail,
				files: st.files, ffree: st.ffree,
			});
	}

	f.close();
	return { result };
}

return {
	'prometheus-exporter.filesystem': {
		mounts: {
			call: function() {
				let core;

				try {
					core = require('luci.core');
				} catch (e) {
					return { error: `luci.core: ${e.message}` };
				}

				return mounts(require('fs'), core.statvfs);
			},
		},
	},
};
