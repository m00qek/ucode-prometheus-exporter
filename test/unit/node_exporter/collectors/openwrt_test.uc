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
				'# HELP node_os_info The operating system release.',
				'# TYPE node_os_info gauge',
				'node_os_info{build_id="r33051-f5dae5ece4",id="openwrt",name="OpenWrt",' +
					'pretty_name="OpenWrt 25.12.5",version="25.12.5",version_id="25.12.5"} 1',
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

	it('fails with SOURCE_INVALID for a board without a release', () => {
		with_collector(openwrt, { ubus: { data: { 'system:board': { model: 'x' } } } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});
});
