'use strict';

const MOUNTS = '/proc/mounts';

function unescape(field) {
	return replace(field, /\\([0-7][0-7][0-7])/g, (m, n) => chr(int(n, 8)));
}

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
