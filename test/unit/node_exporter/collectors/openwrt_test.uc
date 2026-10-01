'use strict';

import { describe, it, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as openwrt from 'node_exporter.collectors.openwrt';

const AP_BOARD = fixtures.ubus('caju-ap', 'system', 'board');
const ROUTER_BOARD = fixtures.ubus('caju-router', 'system', 'board');

describe('collectors.openwrt', () => {
	it('labels node_openwrt_info with the caju AP board and release', () => {
		with_collector(openwrt, { ubus: { data: { 'system:board': AP_BOARD } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_openwrt_info The OpenWrt release and board.',
				'# TYPE node_openwrt_info gauge',
				'node_openwrt_info{board_name="yuncore,ax835",id="OpenWrt",model="YunCore AX835",' +
					'release="25.12.5",revision="r33051-f5dae5ece4",system="ARMv8 Processor rev 4",' +
					'target="mediatek/filogic"} 1',
				'# HELP node_os_info A metric with a constant \'1\' value labeled by build_id, id, id_like, image_id, ' +
					'image_version, name, pretty_name, variant, variant_id, version, version_codename, version_id.',
				'# TYPE node_os_info gauge',
				'node_os_info{build_id="r33051-f5dae5ece4",id="openwrt",name="OpenWrt",' +
					'pretty_name="OpenWrt 25.12.5",version="25.12.5",version_id="25.12.5"} 1',
				'# HELP node_os_version Metric containing the major.minor part of the OS version.',
				'# TYPE node_os_version gauge',
				'node_os_version{id="openwrt",name="OpenWrt"} 25.12',
			], r.lines);
		});
	});

	it('names the caju router target', () => {
		with_collector(openwrt, { ubus: { data: { 'system:board': ROUTER_BOARD } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(true, index(r.text, 'target="rockchip/armv8"') >= 0);
		});
	});

	it('passes a failed ubus call on as the collector result', () => {
		with_collector(openwrt, { ubus: { errors: { 'system:board': 'Permission denied' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'system board: Permission denied' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('reads the major.minor part of a version, as node_exporter', () => {
		assert.match([ 25.12, 24.1, 23, null, null ],
			map([ '25.12.5', '24.10.0-rc1', '23', 'SNAPSHOT', null ], openwrt.version_number));
	});

	it('leaves out node_os_version for a snapshot', () => {
		let board = { ...AP_BOARD, release: { ...AP_BOARD.release, version: 'SNAPSHOT' } };

		with_collector(openwrt, { ubus: { data: { 'system:board': board } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(false, index(r.text, 'node_os_version') >= 0);
		});
	});

	it('fails with SOURCE_INVALID for a board without a release', () => {
		with_collector(openwrt, { ubus: { data: { 'system:board': { model: 'x' } } } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});
});
