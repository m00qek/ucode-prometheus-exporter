'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { popen } from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import { with_mods } from 'context';
import * as commands from 'lib.commands';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

describe('deps.session', () => {
	it('hands a collector exactly its needs', () => {
		with_mods({ time: 1790000000 }, (mods) => {
			let s = deps.session(mods);

			assert.match([ 'fs', 'time' ], sort(keys(s.for({ needs: [ 'time', 'fs' ] }).data)));
			assert.match([], keys(s.for({ needs: [] }).data));
			assert.match(1790000000, s.for({ needs: [ 'time' ] }).data.time.now());
		});
	});

	it('gives fs only the functions collectors may use', () => {
		with_mods({}, (mods) => {
			assert.match(sort([ ...deps.FS_API ]), sort(keys(deps.session(mods).for({ needs: [ 'fs' ] }).data.fs)));
		});
	});

	it('shares one uci cursor across the scrape, the core\'s and the collectors\'', () => {
		with_mods({ uci: { data: { dhcp: { a: { '.type': 'host', name: 'x' } } } } }, (mods) => {
			let cursors = 0;
			let s = deps.session({ ...mods, uci: { cursor: () => { cursors++; return mods.uci.cursor(); } } });
			let meta = { name: 'c', needs: [ 'uci' ], configs: [ 'dhcp' ] };

			s.uci();
			s.for(meta).data.uci.dhcp.loaded();
			s.for(meta).data.uci.dhcp.sections('host');
			assert.match(1, cursors);
		});
	});

	it('gives a collector read-only handles for the configs it declares, and no others', () => {
		let data = {
			dhcp: { lan: { '.type': 'dhcp', 'interface': 'lan' }, h1: { '.type': 'host', name: 'nas', mac: [ 'a', 'b' ] } },
			network: { wg: { '.type': 'interface', private_key: 'secret' } },
		};

		with_mods({ uci: { data } }, (mods) => {
			let uci = deps.session(mods).for({ name: 'c', needs: [ 'uci' ], configs: [ 'dhcp' ] }).data.uci;
			let dhcp = uci.dhcp;

			assert.match([ 'dhcp' ], keys(uci));
			assert.match([ 'foreach', 'get', 'get_all', 'loaded', 'sections' ], sort(keys(dhcp)));
			assert.match([ true, 'nas', 'host' ], [ dhcp.loaded(), dhcp.get('h1', 'name'), dhcp.get('h1') ]);
			assert.match([ 'h1' ], map(dhcp.sections('host'), (s) => s['.name']));
			assert.match([ 'a', 'b' ], dhcp.get_all('h1').mac);

			let seen = [];
			dhcp.foreach('host', (s) => push(seen, s.name));
			assert.match([ 'nas' ], seen);
		});
	});

	it('gives a handle for a missing config that says so and reads nothing', () => {
		with_mods({ uci: { data: {} } }, (mods) => {
			let dhcp = deps.session(mods).for({ name: 'c', needs: [ 'uci' ], configs: [ 'dhcp' ] }).data.uci.dhcp;

			assert.match([ false, null, null, [] ], [ dhcp.loaded(), dhcp.get('h1', 'name'), dhcp.get_all('h1'), dhcp.sections('host') ]);
		});
	});

	prop('hands each collector exactly the configs it declares',
		gen.array(gen.elements('dhcp', 'network', 'wireless', 'system'), { min_len: 1, max_len: 4 }), (configs) => {
			with_mods({ uci: { data: {} } }, (mods) => {
				let uci = deps.session(mods).for({ name: 'c', needs: [ 'uci' ], configs: uniq(configs) }).data.uci;
				assert.match(sort(uniq(configs)), sort(keys(uci)));
			});
		});

	it('fails with NEED_MISSING where rtnl does not load', () => {
		with_mods({ no_rtnl: true }, (mods) => {
			assert.match({ ok: false, error: 'NEED_MISSING', details: 'rtnl is not installed' },
				brief(deps.session(mods).for({ needs: [ 'rtnl' ] })));
		});
	});

	it('fails with NEED_MISSING where ucode-mod-socket is not installed', () => {
		with_mods({ no_socket: true }, (mods) => {
			assert.match({ ok: false, error: 'NEED_MISSING', details: 'socket is not installed' },
				brief(deps.session(mods).for({ needs: [ 'socket' ] })));
		});
	});

	it('fails with NEED_MISSING where nl80211 is not installed', () => {
		with_mods({ no_nl80211: true }, (mods) => {
			let res = deps.session(mods).for({ needs: [ 'fs', 'nl80211' ] });
			assert.match({ ok: false, error: 'NEED_MISSING', details: 'nl80211 is not installed' }, brief(res));
		});
	});

	// One collector that writes over a capability's function must not change
	// what the next gets: they share a session, and a child process.
	it('gives each collector its own deps, so one that writes over them changes no other\'s', () => {
		with_mods({ fs: { behavior: { readfile: () => 'real' } } }, (mods) => {
			let s = deps.session(mods);
			let meta = { name: 'c', needs: [ 'fs', 'ubus', 'time' ] };
			let first = s.for(meta).data;

			first.fs.readfile = () => 'forged';
			first.ubus.call = () => 'forged';
			first.time.now = () => 0;

			let next = s.for(meta).data;

			assert.match([ 'real', false, true ], [ next.fs.readfile('/proc/x'), next.ubus.call == first.ubus.call, next.time.now != first.time.now ]);
		});
	});

	it('names the collector in what it logs, and has no log without the exporter\'s', () => {
		with_mods({}, (mods) => {
			let seen = [];
			deps.session({ ...mods, log: (level, m) => push(seen, [ level, m ]) }).for({ name: 'textfile', needs: [ 'log' ] }).data.log('skipped a.prom');

			assert.match([ [ 'warning', "collector 'textfile': skipped a.prom" ] ], seen);
			assert.match('NEED_MISSING', deps.session(mods).for({ name: 'textfile', needs: [ 'log' ] }).error);
		});
	});

	// 5000 lines of one run once flushed logd's ring of every other daemon's.
	it('takes LOG_LINES lines of a run, of LOG_BYTES each, and says how many more it left out once the run is done', () => {
		with_mods({}, (mods) => {
			let seen = [];
			let s = deps.session({ ...mods, log: (level, m) => push(seen, m) });
			let log = s.for({ name: 'chatty', needs: [ 'log' ] }).data.log;

			for (let i = 0; i < 5000; i++)
				log(`line ${i}`);
			s.done();

			let quiet = s.for({ name: 'quiet', needs: [ 'log' ] }).data.log;

			quiet(sprintf('%2000s', 'long'));
			s.done();
			s.done();

			assert.match([ 10, 2, 12 ], [ deps.LOG_LINES, length(filter(seen, (m) => index(m, "collector 'quiet'") == 0 || index(m, '4990 more') > 0)), length(seen) ]);
			assert.match([ "collector 'chatty': line 0", "collector 'chatty': line 9", "collector 'chatty': 4990 more lines of its log left out" ],
				[ seen[0], seen[9], seen[10] ]);
			assert.match([ length("collector 'quiet': ") + deps.LOG_BYTES + 3, '...' ], [ length(seen[11]), substr(seen[11], -3) ]);
		});
	});

	it('limits exec to the collector\'s commands', () => {
		with_mods({}, (mods) => {
			let exec = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec;
			assert.match('COMMAND_NOT_ALLOWED', exec.run([ 'ethtool', '-S', 'eth0' ]).error);
		});
	});

	it('gives exec the collector\'s meta.timeout, or the default seconds, afresh for each collector', () => {
		let seen = [];
		let fs = { behavior: { popen: function(cmd) { push(seen, commands.parse(cmd).seconds); return null; } } };

		with_mods({ fs }, (mods) => {
			let s = deps.session(mods);

			s.for({ needs: [ 'exec' ], commands: [ 'ubnt-manager' ], timeout: 12 }).data.exec.run([ 'ubnt-manager', '-l' ]);
			s.for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec.run([ 'nft' ]);
		});

		assert.match([ 12, deps.EXEC_SECONDS ], seen);
	});

	it('gives exec the seconds its config settles on over meta.timeout', () => {
		let seen = [];
		let fs = { behavior: { popen: function(cmd) { push(seen, commands.parse(cmd).seconds); return null; } } };

		with_mods({ fs }, (mods) => {
			let s = deps.session(mods);
			let meta = { needs: [ 'exec' ], commands: [ 'nft' ], timeout: 12 };

			s.for(meta, { timeout: 2 }).data.exec.run([ 'nft' ]);
			s.for(meta, { timeout: null }).data.exec.run([ 'nft' ]);
			s.for({ needs: [ 'exec' ], commands: [ 'nft' ] }, { timeout: 9 }).data.exec.run([ 'nft' ]);
		});

		assert.match([ 2, 12, 9 ], seen);
	});

	it('defaults to the main section\'s default exec_timeout', () => {
		assert.match(config.EXEC_TIMEOUT, deps.EXEC_SECONDS);
	});
});

describe('deps.modules', () => {
	it('names every capability the loader accepts', () => {
		assert.match([ 'exec', 'exporter', 'fs', 'log', 'nl80211', 'rtnl', 'socket', 'time', 'ubus', 'uci' ], sort([ ...deps.NEEDS ]));
	});

	// rtnl's and nl80211's real wiring is lint's to check: utest's generated shims
	// for them do not compile (`export const const`), so here they load as missing.
	it('wires the real fs, ubus and uci', () => {
		let m = deps.modules();

		assert.match([ ...deps.FS_API, 'popen' ], filter([ ...deps.FS_API, 'popen' ], (f) => type(m.fs[f]) == 'function'));
		// The handler's, for its state; never a collector's.
		assert.match([ 'function', 'function', 'function', 'function' ], map([ 'writefile', 'rename', 'unlink', 'chmod' ], (f) => type(m.fs[f])));
		assert.match([ false, false, false, false ], map([ 'writefile', 'rename', 'unlink', 'chmod' ], (f) => f in deps.FS_API));
		assert.match([ 'function', 'function', 'function' ], [ type(m.ubus.connect), type(m.uci.cursor), type(m.time) ]);
	});
});
