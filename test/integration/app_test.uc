'use strict';

// The exporter on deps.modules(), the wiring it runs on: fs, ubus and uci are
// patched globally, so the named imports of prometheus_exporter.deps reach the mocks.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { create, handler } from 'prometheus_exporter.app';
import { inflate } from 'zlib';
import * as auth from 'prometheus_exporter.auth';
import * as state from 'prometheus_exporter.state';
import * as deps from 'prometheus_exporter.deps';
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
	// Each load of the collectors holds a descriptor per module it compiled
	// until the garbage collector frees them: a few loads would reach the limit.
	afterEach(() => {
		mock.global.unpatch('fs');
		mock.global.unpatch('ubus');
		mock.global.unpatch('uci');
		gc();
	});

	it('loads the collectors of a directory', () => {
		patch({}, {});
		assert.match(contains([ 'loadavg', 'openwrt' ]), map(create(() => null, SOURCES).collectors(), (c) => c.meta.name));
	});

	it('scrapes the caju router', () => {
		patch(ROUTER.files, { data: { 'system:board': ROUTER.board } });

		let logs = [];
		let res = create((level, m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=openwrt');
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
		let res = create((level, m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=openwrt');

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
		let res = create((level, m) => push(logs, m), SOURCES).scrape('collect[]=loadavg&collect[]=nft-counters&collect[]=openwrt');
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

// A request as uhttpd-mod-ucode hands it: over HTTPS unless `plain`, with
// these headers.
function request(query_string, headers, plain) {
	return { QUERY_STRING: query_string, HTTPS: plain ? null : 'on', headers: { URL: '/metrics', ...(headers ?? {}) } };
}

function basic(text) {
	return 'Basic ' + b64enc(text);
}

// `uhttpd -m secret`.
const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';

describe('app.handler', () => {
	// Each load of the collectors holds a descriptor per module it compiled
	// until the garbage collector frees them: a few loads would reach the limit.
	afterEach(() => {
		mock.global.unpatch('fs');
		mock.global.unpatch('ubus');
		mock.global.unpatch('uci');
		gc();
	});

	function patch_main(main, files) {
		mock.global.patch('fs', { data: { ...ROUTER.files, ...(files ?? {}) } });
		mock.global.patch('ubus', { strict: true, data: {} });
		mock.global.patch('uci', { strict: true, data: { [config.NAME]: main ? { main: { '.type': config.NAME, ...main } } : {} } });
	}

	it('serves a scrape plain, without basic auth\'s file', () => {
		patch_main(null);

		let app = handler(() => null, SOURCES);
		let r = app.handle(request('collect[]=loadavg', {}, true));

		assert.match([ null, true, '200 OK' ], [ app.auth, app.compress, r.status ]);
		assert.match([ [ 'Content-Type', 'text/plain; version=0.0.4; charset=utf-8' ], [ 'Vary', 'Accept-Encoding' ] ], r.headers);
		assert.match(contains([ 'node_load1 0.75' ]), split(r.body, '\n'));
	});

	it('gzips a scrape the scraper asks gzip for', () => {
		patch_main(null);

		let r = handler(() => null, SOURCES).handle(request('collect[]=loadavg', { 'accept-encoding': 'gzip, deflate' }));

		assert.match(contains([ [ 'Content-Encoding', 'gzip' ] ]), r.headers);
		assert.match(contains([ 'node_load1 0.75' ]), split(inflate(r.body), '\n'));
	});

	it('never gzips with compress off', () => {
		patch_main({ compress: '0' });

		let app = handler(() => null, SOURCES);
		let r = app.handle(request('collect[]=loadavg', { 'accept-encoding': 'gzip' }));

		assert.match([ false, [ [ 'Content-Type', 'text/plain; version=0.0.4; charset=utf-8' ] ] ], [ app.compress, r.headers ]);
		assert.match(contains([ 'node_load1 0.75' ]), split(r.body, '\n'));
	});

	it('answers 401 without the user and password of basic auth\'s file, and scrapes with them', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let app = handler(() => null, SOURCES);
		let none = app.handle(request('collect[]=loadavg'));
		let wrong = app.handle(request('collect[]=loadavg', { authorization: basic('prom:wrong') }));
		let right = app.handle(request('collect[]=loadavg', { authorization: basic('prom:secret'), 'accept-encoding': 'gzip' }));

		assert.match({ user: 'prom', hash: HASH }, app.auth);
		assert.match([ '401 Unauthorized', '401 Unauthorized', '200 OK' ], [ none.status, wrong.status, right.status ]);
		assert.match(contains([ [ 'WWW-Authenticate', 'Basic realm="prometheus-exporter"' ] ]), none.headers);
		assert.match('Unauthorized.\n', none.body);
		assert.match(contains([ 'node_load1 0.75' ]), split(inflate(right.body), '\n'));
	});

	// The state in a directory of the mock's, its files those of this process's instance.
	const STATE = '/test-state';

	function cached_file() {
		return `${STATE}/${state.instance_id(deps.modules().fs)}.${auth.CACHE}`;
	}

	it('keeps the header it let in, in the instance\'s state, and lets it in again by it', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let fs = deps.modules().fs;
		let app = handler(() => null, SOURCES, STATE);
		let right = request('collect[]=loadavg', { authorization: basic('prom:secret') });

		assert.match([ '200 OK', auth.digest({ user: 'prom', hash: HASH }, basic('prom:secret')) ], [ app.handle(right).status, fs.readfile(cached_file()) ]);
		assert.match([ '200 OK', '401 Unauthorized' ], [ app.handle(right).status, app.handle(request('', { authorization: basic('prom:wrong') })).status ]);
	});

	// The digest of a wrong password's header, as if a request had left it:
	// let in only because the hash is not computed.
	it('lets in the header the cache holds without the full check', () => {
		let wrong = basic('prom:not-the-password');

		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH), [cached_file()]: auth.digest({ user: 'prom', hash: HASH }, wrong) });

		assert.match('200 OK', handler(() => null, SOURCES, STATE).handle(request('collect[]=loadavg', { authorization: wrong })).status);
	});

	it('starts without the state of another instance, which it removes', () => {
		let other = `${STATE}/1-1.${auth.CACHE}`;

		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH), [other]: auth.digest({ user: 'prom', hash: HASH }, basic('prom:wrong')) });

		let app = handler(() => null, SOURCES, STATE);

		assert.match([ null, '401 Unauthorized' ], [ deps.modules().fs.readfile(other), app.handle(request('', { authorization: basic('prom:wrong') })).status ]);
	});

	it('answers 403 to basic auth over HTTP, before reading credentials', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let r = handler(() => null, SOURCES).handle(request('', { authorization: basic('prom:secret') }, true));

		assert.match([ '403 Forbidden', 'Basic auth takes HTTPS only.\n' ], [ r.status, r.body ]);
	});

	it('denies every request when the file is not what it should be, and logs why without the hash', () => {
		patch_main(null, { [auth.FILE]: '/metrics:prom:secret\n' });

		let logs = [];
		let app = handler((level, m) => push(logs, [ level, m ]), SOURCES);
		let r = app.handle(request('', { authorization: basic('prom:secret') }));

		assert.match([ { broken: true }, '500 Internal Server Error' ], [ app.auth, r.status ]);
		assert.match([ [ 'err', `${auth.FILE} is not one line of a user and a hash for /metrics: every request is denied` ] ], logs);
	});
});

