'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/openwrt.uc and
// utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/openwrt.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'openwrt',
	title: 'OpenWrt release and board',
	help: 'The OpenWrt release and board, from ubus system board.',
	needs: [ 'ubus' ],
};

// The major.minor part of a version, as node_exporter reads VERSION_ID: "25.12.5"
// is 25.12, "SNAPSHOT" null.
export function version_number(version) {
	let m = match(version ?? '', /^[0-9]+\.?[0-9]*/);

	return m ? +m[0] : null;
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

	// node_exporter's os collector (collector/os_release.go), from what OpenWrt
	// publishes besides /etc/os-release: the labels ubus has the values of.
	let id = lc(release.distribution ?? '');

	out.gauge('node_os_info', 'A metric with a constant \'1\' value labeled by build_id, id, id_like, image_id, ' +
		'image_version, name, pretty_name, variant, variant_id, version, version_codename, version_id.')({
		build_id: release.revision,
		id,
		name: release.distribution,
		pretty_name: `${release.distribution} ${release.version}`,
		version: release.version,
		version_id: release.version,
	}, 1);

	// As node_exporter, none for a version without a number (SNAPSHOT).
	let major_minor = version_number(release.version);
	if (major_minor > 0)
		out.gauge('node_os_version', 'Metric containing the major.minor part of the OS version.')(
			{ id, name: release.distribution }, major_minor);

	return Result.ok();
};
