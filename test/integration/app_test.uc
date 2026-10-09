'use strict';

// The exporter on deps.modules(), the wiring it runs on: fs, ubus and uci are
// patched globally, so the named imports of prometheus_exporter.deps reach the mocks.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { create, handler, load_auth, auth_wanted, load_checked, load_probed } from 'prometheus_exporter.app';
import * as app_mod from 'prometheus_exporter.app';
import * as loader from 'prometheus_exporter.loader';
import * as collection from 'prometheus_exporter.collection';
import { inflate } from 'zlib';
import * as auth from 'prometheus_exporter.auth';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';
import * as deps from 'prometheus_exporter.deps';
import * as exposition from 'prometheus_exporter.exposition';
import * as config from 'prometheus_exporter.config';
import * as fixtures from 'lib.fixtures';
import * as commands from 'prometheus_exporter.devkit.commands';
import * as lockable from 'lib.lockable';

const SOURCES = 'src/prometheus_exporter/collectors';
// As root on a router, with every capability: nft-counters declares
// CAP_NET_ADMIN, which the session checks the process has.
const ROOT_STATUS = 'Name:\tuhttpd\nUid:\t0\t0\t0\t0\nCapEff:\t000001ffffffffff\n';
const ROUTER = {
	files: { ...fixtures.files('caju-router', [ '/proc/loadavg' ]), '/proc/self/status': ROOT_STATUS },
	board: fixtures.ubus('caju-router', 'system', 'board'),
};

// Not strict: the loader lists the real source directory.
function patch(files, ubus) {
	mock.global.patch('fs', { data: files, behavior: { mkstemp: lockable.mkstemp } });
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

	// Checked in the probe's child, loaded here without the loader: each
	// as it was there, or not at all.
	it('loads a collector checked elsewhere only when its meta is what was checked', () => {
		let meta = loader.validate('loadavg', loader.import_module('loadavg')).data.meta;
		let logs = [];
		let loaded = load_checked([
			{ id: 'loadavg', meta: collection.fingerprint(meta), own: true },
			{ id: 'uname', meta: collection.fingerprint(meta), own: true },
			{ id: 'does_not_exist', meta: 'x', own: false },
		], (level, m) => push(logs, [ level, m ]));

		assert.match([ [ 'loadavg', true, meta ] ], map(loaded, (c) => [ c.id, c.own, c.meta ]));
		assert.match([
			'notice', 'err', 'err',
		], map(logs, (l) => l[0]));
		assert.match("skipping collector: uname: not what it was when it was checked, in a process of its own", logs[1][1]);
	});

	// An upgrade of several packages: a collector's file changes between
	// its check in the probe's child and its load here, as apk writes the
	// next package while the service starts. Each module is a version of
	// loadavg's meta: `versions[id]` is what its file holds at each read.
	// They share loadavg's name, so their order is not checked.
	describe('load_probed', () => {
		const LOADAVG = loader.import_module('loadavg');

		function version(n) {
			return { meta: { ...LOADAVG.meta, help: `${LOADAVG.meta.help} ${n}` }, collect: LOADAVG.collect };
		}

		// The probe and the imports over files that change: each read of a
		// module takes its file's next version, and stays at its last.
		function world(versions) {
			let reads = {};
			let read = function(id) {
				let n = reads[id] ?? 0;

				reads[id] = n + 1;
				return version(versions[id][min(n, length(versions[id]) - 1)]);
			};
			let probes = [];

			return {
				probes,
				probe: function(ids) {
					let out = {};

					push(probes, ids);
					for (let id in ids)
						out[id] = { ok: true, error: null, hung: false, seconds: 0,
							data: { meta: collection.fingerprint({ options: {}, ...read(id).meta }), own: true } };
					return out;
				},
				imports: {
					all: function(ids) {
						let out = {};

						for (let id in ids)
							out[id] = read(id);
						return out;
					},
					one: read,
				},
			};
		}

		it('checks again a module that changed between its check and its load, and loads it alone', () => {
			let w = world({ a: [ 1, 1 ], b: [ 1, 2, 2 ] });
			let logs = [];
			let res = load_probed([ 'a', 'b' ], w.probe, (level, m) => push(logs, [ level, m ]), w.imports);

			assert.match([ [ 'a', 'b' ], [ 'b' ] ], w.probes);
			assert.match([ 'a', 'b' ], sort(map(res.collectors, (c) => c.id)));
			assert.match(`${LOADAVG.meta.help} 2`, filter(res.collectors, (c) => c.id == 'b')[0].meta.help);
			assert.match([ [ 'info', 'checking again what changed since it was checked, as in an upgrade: b' ] ], logs);
		});

		it('leaves out, at err, a module that changed at every check', () => {
			let w = world({ a: [ 1, 1 ], b: [ 1, 2, 3, 4, 5, 6, 7 ] });
			let logs = [];
			let res = load_probed([ 'a', 'b' ], w.probe, (level, m) => push(logs, [ level, m ]), w.imports);

			assert.match(app_mod.CHECK_ROUNDS, length(w.probes));
			assert.match([ 'a' ], map(res.collectors, (c) => c.id));
			assert.match([ 'err', `skipping collector: b: not what it was when it was checked, in a process of its own, ${app_mod.CHECK_ROUNDS} times: is it being upgraded?` ], logs[-1]);
		});

		// Before, a module without an outcome was taken as checked, with no
		// meta, and every one of them was left out.
		it('checks again a module the probe gave no outcome of', () => {
			let w = world({ a: [ 1 ], b: [ 1 ] });
			let first = true;
			let probe = function(ids) {
				let out = w.probe(ids);

				if (first)
					delete out.b;
				first = false;
				return out;
			};
			let res = load_probed([ 'a', 'b' ], probe, () => null, w.imports);

			assert.match([ 'a', 'b' ], sort(map(res.collectors, (c) => c.id)));
		});

		it('loads nothing when this process was asked to stop while the probe loaded them', () => {
			let w = world({ a: [ 1 ], b: [ 1 ] });
			let probe = (ids) => ({ ...w.probe(ids), b: { ok: false, error: 'not loaded: this process was asked to stop (signal 15)', hung: false, seconds: 0, stopped: 15 } });

			assert.match({ collectors: [], stopped: 15 }, load_probed([ 'a', 'b' ], probe, () => null, w.imports));
		});

		it('says when no child could check them', () => {
			let probe = (ids) => ({ a: { ok: true, error: null, hung: false, seconds: 0, unprobed: true } });

			assert.match({ collectors: [], unprobed: true }, load_probed([ 'a' ], probe, () => null, null));
		});
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
	it('has the collectors read what opts.observed gives them, and that alone', () => {
		patch(ROUTER.files, { data: { 'system:board': ROUTER.board } });

		let real = deps.modules();
		let observed = { ...real, fs: { ...real.fs, readfile: (p, n) => (p == '/proc/loadavg') ? '9.50 0.10 0.05 1/2 3\n' : real.fs.readfile(p, n) } };
		let app = create(() => null, SOURCES, { fork: false, observed });

		assert.match(contains([ 'node_load1 9.5' ]), split(app.scrape('collect[]=loadavg').body, '\n'));
		assert.match(contains([ 'node_load1 0.75' ]), split(create(() => null, SOURCES, { fork: false }).scrape('collect[]=loadavg').body, '\n'));
	});

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
		}, { data: ROUTER.files, behavior: { mkstemp: lockable.mkstemp } }));
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
		mock.global.patch('fs', { data: { ...ROUTER.files, ...(files ?? {}) }, behavior: lockable.behavior });
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

	// The budget of a 2 s timeout is 1.5 s: a program gets its whole second.
	it('gives a program no more than the scraper\'s timeout leaves, and scrape_timeout without one', () => {
		let seen = [];

		mock.global.patch('fs', { data: ROUTER.files, behavior: {
			...lockable.behavior,
			popen: function(cmd) { push(seen, commands.parse(cmd).seconds); return { read: () => '{}', close: () => 0 }; },
		} });
		mock.global.patch('ubus', { strict: true, data: {} });
		mock.global.patch('uci', { strict: true, data: { [config.NAME]: { main: { '.type': config.NAME, scrape_timeout: '3' } } } });

		// The collectors run in this process, where the mock sees their programs.
		let app = handler(() => null, SOURCES, null, { fork: false });

		app.handle(request('collect[]=nft-counters', { 'x-prometheus-scrape-timeout-seconds': '2' }, true));
		app.handle(request('collect[]=nft-counters', { 'x-prometheus-scrape-timeout-seconds': '30' }, true));
		app.handle(request('collect[]=nft-counters', {}, true));

		assert.match([ 3, [ 1, 5, 2 ] ], [ app.scrape_timeout, seen ]);
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

	it('counts its scrapes and the requests basic auth refused in the instance\'s ledger', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let fs = deps.modules().fs;
		let app = handler(() => null, SOURCES, STATE);
		let ledger_file = `${STATE}/${state.instance_id(fs)}.${ledger.NAME}`;

		app.handle(request('collect[]=loadavg', { authorization: basic('prom:secret') }));
		app.handle(request('collect[]=loadavg', { authorization: basic('prom:wrong') }));
		app.handle(request('collect[]=loadavg'));
		app.handle(request('collect[]=loadavg', { authorization: basic('prom:secret') }));

		let l = ledger.parse(fs.readfile(ledger_file));

		assert.match([ 2, 2 ], [ l.scrapes, l.auth_failures ]);
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

	it('denies every request when the config sets basic auth and the file is not there, as after a respawn without it', () => {
		patch_main({ auth_user: 'prom', cert: '/etc/x.crt', key: '/etc/x.key' });

		let logs = [];
		let app = handler((level, m) => push(logs, [ level, m ]), SOURCES);

		for (let req in [ request('', { authorization: basic('prom:secret') }, true), request('', {}, true), request('', {}) ])
			assert.match('500 Internal Server Error', app.handle(req).status);
		assert.match({ broken: true, missing: true }, app.auth);
		assert.match([ [ 'err', `${auth.FILE} is not there, and the config sets basic auth (auth_user): every request is denied` ] ], logs);
	});

	// Basic auth's module is compiled when the handler finds its file: should
	// that fail, whatever the reason, the handler fails closed, as without
	// the file, and never serves a request, the right credentials' included.
	const UNLOADABLE = {
		'its file is missing, or not mounted in the jail': "import * as auth from 'prometheus_exporter.no_such_module';\nreturn auth;",
		'it is not there by its path': "import * as auth from '/nonexistent/prometheus_exporter/auth.uc';\nreturn auth;",
		'it does not compile': 'return {',
		'loading it runs out of memory': "die('out of memory');",
		'it is not basic auth\'s module': 'return { parse_conf: () => null };',
	};

	it('denies every request when basic auth\'s module does not load, with the config\'s user or without it', () => {
		for (let why, program in UNLOADABLE)
			for (let main in [ null, { auth_user: 'prom', cert: '/etc/x.crt', key: '/etc/x.key' } ]) {
				patch_main(main, { [auth.FILE]: auth.conf('prom', HASH) });

				let logs = [];
				let app = handler((level, m) => push(logs, [ level, m ]), SOURCES, null, { auth_program: program });

				for (let req in [ request('collect[]=loadavg', { authorization: basic('prom:secret') }), request('collect[]=loadavg', {}) ])
					assert.match('500 Internal Server Error', app.handle(req).status, why);
				assert.match([ true, 'string' ], [ app.auth?.broken, type(app.auth?.unloaded) ], why);
				assert.match([ 'err' ], map(logs, (l) => l[0]), why);
				assert.match(true, index(logs[0][1], 'cannot load basic auth\'s module') == 0 && index(logs[0][1], 'every request is denied') > 0, why);
			}
	});

	it('denies the request when basic auth\'s check fails, rather than letting it in', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let program = "import * as auth from 'prometheus_exporter.auth';\nreturn { ...auth, allowed: () => die('out of memory') };";
		let app = handler(() => null, SOURCES, null, { auth_program: program });

		assert.match({ user: 'prom', hash: HASH }, app.auth);
		assert.match('500 Internal Server Error', app.handle(request('collect[]=loadavg', { authorization: basic('prom:secret') })).status);
	});

	it('lets nothing in by a check that gives anything but true', () => {
		patch_main(null, { [auth.FILE]: auth.conf('prom', HASH) });

		let program = "import * as auth from 'prometheus_exporter.auth';\nreturn { ...auth, allowed: () => 1 };";

		assert.match('401 Unauthorized', handler(() => null, SOURCES, null, { auth_program: program })
			.handle(request('collect[]=loadavg', { authorization: basic('prom:secret') })).status);
	});

	it('serves without the file when the config sets no basic auth, an empty user included', () => {
		for (let main in [ null, { auth_user: '' } ]) {
			patch_main(main);

			let app = handler(() => null, SOURCES);

			assert.match([ null, '200 OK' ], [ app.auth, app.handle(request('collect[]=loadavg', {}, true)).status ], main);
		}
	});
});

describe('app.load_auth and app.auth_wanted', () => {
	const files = (text) => ({ readfile: (p) => (p == auth.FILE) ? text : null });

	it('is null without the file only when the config sets no basic auth', () => {
		assert.match([ null, { broken: true, missing: true } ], [ load_auth(files(null), false), load_auth(files(null), true) ]);
	});

	it('names where uhttpd\'s file is as auth does', () => {
		assert.match(auth.FILE, app_mod.AUTH_FILE);
	});

	it('denies everything when the file is there and basic auth\'s module does not load', () => {
		for (let wanted in [ false, true ]) {
			let res = load_auth(files(auth.conf('prom', HASH)), wanted, 'return {');

			assert.match([ true, 'string' ], [ res.broken, type(res.unloaded) ]);
		}
	});

	it('takes the file when it is there, whatever the config says, and denies a file that is not right', () => {
		for (let wanted in [ false, true ]) {
			assert.match({ user: 'prom', hash: HASH }, load_auth(files(auth.conf('prom', HASH)), wanted));
			assert.match({ broken: true }, load_auth(files('nonsense\n'), wanted));
		}
	});

	it('reads the main section\'s auth_user alone', () => {
		let wanted = (sections) => {
			let out;

			mock.inject('uci', { strict: true, data: { [config.NAME]: sections } }, (uci) => { out = auth_wanted(uci.cursor()); });
			return out;
		};

		assert.match([ true, false, false, false, true ], [
			wanted({ main: { '.type': config.NAME, auth_user: 'prom' } }),
			wanted({ main: { '.type': config.NAME, auth_user: '' } }),
			wanted({ main: { '.type': config.NAME } }),
			wanted({ main: { '.type': 'other', auth_user: 'prom' } }),
			// An invalid section still asks for a login: the handler fails closed.
			wanted({ main: { '.type': config.NAME, auth_user: 'a user:with a colon', listen_port: 'http' } }),
		]);
	});
});

