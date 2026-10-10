'use strict';

// The filesystem package's rpcd plugin, as rpcd loads it: the object it
// returns, and its method run for real on the devenv's mounts, with the
// luci.core of the OpenWrt image the tests run in.

import { describe, it, assert } from 'utest';

const PLUGIN = 'files/usr/share/rpcd/ucode/prometheus-exporter-filesystem.uc';

function mounts() {
	return loadfile(PLUGIN)()['prometheus-exporter.filesystem'].mounts.call({});
}

describe('the filesystem rpcd plugin', () => {
	it('serves prometheus-exporter.filesystem, with mounts its one method', () => {
		let plugin = loadfile(PLUGIN)();

		assert.match([ 'prometheus-exporter.filesystem' ], keys(plugin));
		assert.match([ 'mounts' ], keys(plugin['prometheus-exporter.filesystem']));
	});

	it("sizes and counts the inodes of each mount with blocks, with its fstype and read-only flag", () => {
		let reply = mounts();

		assert.match('array', type(reply.result), sprintf('%J', reply));
		assert.match(true, length(reply.result) > 0);

		for (let m in reply.result) {
			assert.match([ 'device', 'mount', 'fstype', 'ro', 'size', 'free', 'avail', 'files', 'ffree' ], keys(m));
			assert.match([ 'string', 'bool' ], [ type(m.fstype), type(m.ro) ], sprintf('%J', m));
			assert.match(true, m.size > 0 && m.free <= m.size && m.avail <= m.free, sprintf('%J', m));
			assert.match(true, type(m.files) == 'int' && type(m.ffree) == 'int' && m.ffree <= m.files, sprintf('%J', m));
		}

		// The tests' checkout is a mount of its own, read-only; procfs has no blocks.
		assert.match([ true ], map(filter(reply.result, (m) => m.mount == '/exporter'), (m) => m.ro));
		assert.match(0, length(filter(reply.result, (m) => m.mount == '/proc')));
	});
});
