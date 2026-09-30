'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/openwrt.uc and
// utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/openwrt.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'openwrt',
	help: 'The OpenWrt release and board, from ubus system board.',
	needs: [ 'ubus' ],
};

export function collect(deps, out) {
	let res = deps.ubus.call('system', 'board');

	if (!res.ok)
		return res;

	let board = res.data;
	let release = board?.release;
	if (type(release) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'system board: no release');

	out.gauge('node_openwrt_info', 'The OpenWrt release and board.')({
		board_name: board.board_name,
		id: release.distribution,
		model: board.model,
		release: release.version,
		revision: release.revision,
		system: board.system,
		target: release.target,
	}, 1);

	// node_exporter's os collector, from what OpenWrt publishes instead of /etc/os-release.
	out.gauge('node_os_info', 'The operating system release.')({
		build_id: release.revision,
		id: lc(release.distribution ?? ''),
		name: release.distribution,
		pretty_name: `${release.distribution} ${release.version}`,
		version: release.version,
		version_id: release.version,
	}, 1);

	return Result.ok();
};
