'use strict';

// The exporter on deps.modules(), the wiring it runs on: fs, ubus and uci are
// patched globally, so the named imports of prometheus_exporter.deps reach the mocks.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { create } from 'prometheus_exporter.app';
import * as exposition from 'prometheus_exporter.exposition';
import * as config from 'prometheus_exporter.config';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';

const SOURCES = 'src/prometheus_exporter/collectors';
const ROUTER = {
	files: fixtures.files('caju-router', [ '/proc/loadavg' ]),
	board: fixtures.ubus('caju-router', 'system', 'board'),
};

// Not strict: the loader lists the real source directory.
function patch(files, ubus) {
	mock.global.patch('fs', { data: files });
	mock.global.patch('ubus', { strict: true, ...ubus });
	mock.global.patch('uci', { strict: true, data: { [config.NAME]: {} } });
}

describe('app', () => {
	afterEach(() => {
		mock.global.unpatch('fs');
		mock.global.unpatch('ubus');
		mock.global.unpatch('uci');
	});

	it('loads the collectors of a directory', () => {
		patch({}, {});
		assert.match(contains([ 'loadavg', 'openwrt' ]), map(create(() => null, SOURCES).collectors(), (c) => c.meta.name));
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

	// A source tree's version: the package Makefile writes the package's in.
	it('labels the build with its version', () => {
		patch(ROUTER.files, {});
		assert.match(contains([ 'ucode_prometheus_exporter_build_info{version="dev"} 1' ]),
			split(create(() => null, SOURCES).scrape('collect[]=loadavg').body, '\n'));
	});

	it('reports a collector whose source is down as failed, and still answers', () => {
		patch(ROUTER.files, { errors: { 'system:board': 'Not found' } });

		let logs = [];
		let res = create((m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=openwrt');

		assert.match('200 OK', res.status);
		assert.match(contains([ 'node_scrape_collector_success{collector="openwrt"} 0' ]), split(res.body, '\n'));
		assert.match([ "collector 'openwrt': UBUS_CALL_FAILED (system board: Not found)" ], logs);
	});

	// nft as a shell that starts a child and never finishes, run for real under
	// exec's watchdog, its limit made 1 s so the test does not wait out 5.
	it('answers with every other collector when one\'s program hangs, and kills it', () => {
		mock.global.patch('fs', commands.fs({
			[commands.line([ 'nft', '--json', 'list', 'counters' ])]: { run: [ 'sh', '-c', 'sleep 3071; :' ], seconds: 1 },
		}, { data: ROUTER.files }));
		mock.global.patch('ubus', { strict: true, data: { 'system:board': ROUTER.board } });
		mock.global.patch('uci', { strict: true, data: { [config.NAME]: {} } });

		let logs = [];
		let t = clock(true);
		let res = create((m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=nft-counters&collect[]=openwrt');
		let took = clock(true)[0] - t[0];

		assert.match('200 OK', res.status);
		assert.match(contains([
			'node_load1 0.75',
			'node_scrape_collector_success{collector="loadavg"} 1',
			'node_scrape_collector_success{collector="nft-counters"} 0',
			'node_scrape_collector_success{collector="openwrt"} 1',
		]), split(res.body, '\n'));
		assert.match([ "collector 'nft-counters': COMMAND_TIMEOUT (nft: still running after 5 s, killed)" ], logs);
		assert.match(true, took < 4);
		assert.match([], commands.running('sleep 3071'));
	});
});
