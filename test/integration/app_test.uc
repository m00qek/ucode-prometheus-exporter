'use strict';

// The exporter on deps.modules(), the wiring it runs on: fs, ubus and uci are
// patched globally, so the named imports of node_exporter.deps reach the mocks.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { create } from 'node_exporter.app';
import * as exposition from 'node_exporter.exposition';
import * as config from 'node_exporter.config';
import * as fixtures from 'lib.fixtures';

const SOURCES = 'src/node_exporter/collectors';
const ROUTER = {
	files: fixtures.files('caju-router', [ '/proc/loadavg' ]),
	board: fixtures.ubus('caju-router', 'system', 'board'),
};

// Not strict: the loader lists the real source directory.
function patch(files, ubus) {
	mock.global.patch('fs', { data: files });
	mock.global.patch('ubus', { strict: true, ...ubus });
	mock.global.patch('uci', { strict: true, data: { [config.PACKAGE]: {} } });
}

describe('app', () => {
	afterEach(() => {
		mock.global.unpatch('fs');
		mock.global.unpatch('ubus');
		mock.global.unpatch('uci');
	});

	it('loads the collectors of a directory', () => {
		patch({}, {});
		assert.match(contains([ 'loadavg', 'openwrt' ]), map(create(() => null, SOURCES).collectors, (c) => c.meta.name));
	});

	it('scrapes the caju router', () => {
		patch(ROUTER.files, { data: { 'system:board': ROUTER.board } });

		let logs = [];
		let res = create((m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=openwrt');
		let parsed = exposition.parse(res.body);

		assert.match([ '200 OK', true, [] ], [ res.status, parsed.ok, logs ]);
		assert.match(contains([
			'node_load1 0.75',
			'node_scrape_collector_success{collector="loadavg"} 1',
			'node_scrape_collector_success{collector="openwrt"} 1',
		]), split(res.body, '\n'));
		assert.match(true, index(res.body, 'node_openwrt_info{board_name="friendlyarm,nanopi-r5c",') >= 0);
	});

	it('reports a collector whose source is down as failed, and still answers', () => {
		patch(ROUTER.files, { errors: { 'system:board': 'Not found' } });

		let logs = [];
		let res = create((m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=openwrt');

		assert.match('200 OK', res.status);
		assert.match(contains([ 'node_scrape_collector_success{collector="openwrt"} 0' ]), split(res.body, '\n'));
		assert.match([ "collector 'openwrt': UBUS_CALL_FAILED (system board: Not found)" ], logs);
	});
});
