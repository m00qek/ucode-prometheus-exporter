'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import { popen } from 'fs';
import * as deps from 'node_exporter.deps';
import { with_mods } from 'context';
import * as commands from 'lib.commands';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

// A popen whose handles answer `outputs[cmd]` = { out, status }: utest's fs mock
// closes a popen handle without the exit status real ucode gives.
function popen_answering(outputs, seen) {
	return function(cmd, mode) {
		push(seen, cmd);
		let o = outputs[cmd];
		return o == null ? null : { read: () => o.out, close: () => o.status };
	};
}

describe('deps.ubus_channel', () => {
	it('connects on the first call only', () => {
		mock.inject('ubus', { strict: true, data: { 'system:board': { model: 'm' } } }, (ubus) => {
			let connects = 0;
			let ch = deps.ubus_channel(() => { connects++; return ubus.connect(); });

			assert.match(0, connects);
			assert.match({ ok: true, data: { model: 'm' } }, brief(ch.call('system', 'board')));
			ch.call('system', 'board');
			assert.match(1, connects);
		});
	});

	it('tells a method without data from a failed call', () => {
		mock.inject('ubus', { strict: true, data: { 'svc:quiet': null }, errors: { 'svc:broken': 'Not found' } }, (ubus) => {
			let ch = deps.ubus_channel(ubus.connect);

			assert.match({ ok: true, data: null }, brief(ch.call('svc', 'quiet')));
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'svc broken: Not found' }, brief(ch.call('svc', 'broken')));
		});
	});

	it('fails every call when ubusd cannot be reached', () => {
		let ch = deps.ubus_channel(() => null);

		assert.match([ 'UBUS_CONNECT_FAILED', 'UBUS_CONNECT_FAILED' ], [ ch.call('a', 'b').error, ch.list().error ]);
	});

	it('lists the published objects', () => {
		mock.inject('ubus', { strict: true, data: { 'hostapd.phy0-ap0:get_clients': {}, 'system:board': {}, 'system:info': {} } }, (ubus) => {
			assert.match([ 'hostapd.phy0-ap0', 'system' ], deps.ubus_channel(ubus.connect).list().data);
		});
	});

	it('disconnects on close and connects again after', () => {
		mock.inject('ubus', { strict: true, data: { 'a:b': 1 } }, (ubus) => {
			let conns = [];
			let ch = deps.ubus_channel(() => { let c = ubus.connect(); push(conns, c); return c; });

			ch.call('a', 'b');
			ch.close();
			ch.call('a', 'b');
			assert.match([ 1, 0 ], map(conns, (c) => length(c.__utest__.calls.disconnect)));
		});
	});
});

describe('deps.nl80211_channel', () => {
	it('answers requests as Results and passes the constants through', () => {
		mock.inject('nl80211', {
			strict: true,
			data: { 'NL80211_CMD_GET_INTERFACE:wlan0': { ifname: 'wlan0' }, 'NL80211_CMD_GET_SURVEY': null },
			errors: { 'NL80211_CMD_GET_STATION:wlan0': 'No such device' },
		}, (nl) => {
			let ch = deps.nl80211_channel(nl);
			let c = ch.const;

			assert.match({ ok: true, data: { ifname: 'wlan0' } }, brief(ch.request(c.NL80211_CMD_GET_INTERFACE, 0, { dev: 'wlan0' })));
			assert.match({ ok: true, data: null }, brief(ch.request(c.NL80211_CMD_GET_SURVEY, c.NLM_F_DUMP, { dev: 'wlan0' })));
			assert.match({ ok: false, error: 'NL80211_FAILED', details: 'No such device' },
				brief(ch.request(c.NL80211_CMD_GET_STATION, c.NLM_F_DUMP, { dev: 'wlan0' })));
		});
	});
});

describe('deps.rtnl_channel', () => {
	it('answers requests as Results and passes the constants through', () => {
		mock.inject('rtnl', {
			strict: true,
			data: { 'RTM_GETLINK': [ { dev: 'lo', mtu: 65536 } ] },
			errors: { 'RTM_GETLINK:nope': 'No such device' },
		}, (rtnl) => {
			let ch = deps.rtnl_channel(rtnl);
			let c = ch.const;

			assert.match({ ok: true, data: [ { dev: 'lo', mtu: 65536 } ] }, brief(ch.request(c.RTM_GETLINK, c.NLM_F_DUMP, {})));
			assert.match({ ok: false, error: 'RTNL_FAILED', details: 'No such device' },
				brief(ch.request(c.RTM_GETLINK, 0, { dev: 'nope' })));
		});
	});
});

describe('deps.exec_channel', () => {
	it('runs an allowed program with quoted arguments, without its stderr', () => {
		let seen = [];
		let ch = deps.exec_channel(popen_answering({ "'nft' '--json' 'list counters' 2>/dev/null": { out: '{}', status: 0 } }, seen), [ 'nft' ]);

		assert.match({ ok: true, data: '{}' }, brief(ch.run([ 'nft', '--json', 'list counters' ])));
		assert.match([ "'nft' '--json' 'list counters' 2>/dev/null" ], seen);
	});

	it('refuses a program not in the allowlist, without running anything', () => {
		let seen = [];
		let ch = deps.exec_channel(popen_answering({}, seen), [ 'nft' ]);

		assert.match({ ok: false, error: 'COMMAND_NOT_ALLOWED', details: 'sh' }, brief(ch.run([ 'sh', '-c', 'reboot' ])));
		assert.match([], seen);
	});

	it('fails on a non-zero exit status, and on a program that cannot start', () => {
		let ch = deps.exec_channel(popen_answering({ "'mmcli' '-L' 2>/dev/null": { out: '', status: 1 } }, []), [ 'mmcli', 'nope' ]);

		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'mmcli: exit status 1' }, brief(ch.run([ 'mmcli', '-L' ])));
		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'nope: cannot start' }, brief(ch.run([ 'nope' ])));
	});

	prop('quotes any argument so a real shell passes it on unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (arg) => {
		let p = popen("printf '%s' " + deps.shell_quote(arg), 'r');
		let out = p.read('all');
		p.close();

		assert.match(arg, out);
	});
});

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

	it('shares one uci cursor across the scrape', () => {
		with_mods({}, (mods) => {
			let s = deps.session(mods);
			assert.match(true, s.uci() === s.for({ needs: [ 'uci' ] }).data.uci);
		});
	});

	it('fails with NEED_MISSING where rtnl does not load', () => {
		with_mods({ no_rtnl: true }, (mods) => {
			assert.match({ ok: false, error: 'NEED_MISSING', details: 'rtnl is not installed' },
				brief(deps.session(mods).for({ needs: [ 'rtnl' ] })));
		});
	});

	it('fails with NEED_MISSING where nl80211 is not installed', () => {
		with_mods({ no_nl80211: true }, (mods) => {
			let res = deps.session(mods).for({ needs: [ 'fs', 'nl80211' ] });
			assert.match({ ok: false, error: 'NEED_MISSING', details: 'nl80211 is not installed' }, brief(res));
		});
	});

	it('limits exec to the collector\'s commands', () => {
		with_mods({}, (mods) => {
			let exec = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec;
			assert.match('COMMAND_NOT_ALLOWED', exec.run([ 'ethtool', '-S', 'eth0' ]).error);
		});
	});
});

describe('deps.modules', () => {
	it('names every capability the loader accepts', () => {
		assert.match([ 'exec', 'fs', 'nl80211', 'rtnl', 'time', 'ubus', 'uci' ], sort([ ...deps.NEEDS ]));
	});

	// rtnl's and nl80211's real wiring is lint's to check: utest's generated shims
	// for them do not compile (`export const const`), so here they load as missing.
	it('wires the real fs, ubus and uci', () => {
		let m = deps.modules();

		assert.match([ ...deps.FS_API, 'popen' ], filter([ ...deps.FS_API, 'popen' ], (f) => type(m.fs[f]) == 'function'));
		assert.match([ 'function', 'function', 'function' ], [ type(m.ubus.connect), type(m.uci.cursor), type(m.time) ]);
	});

	it('gives no rtnl or nl80211 when they do not load', () => {
		assert.match([ null, null ], [ deps.load_rtnl(), deps.load_nl80211() ]);
	});
});

describe('test/lib/commands', () => {
	it('fakes what exec runs, exit status included', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { out: '{}', status: 0 }, [commands.line([ 'nft', 'x' ])]: { out: '', status: 2 } }) }, (mods) => {
			let exec = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec;

			assert.match([ true, '{}', 'nft: exit status 2', 'nft: cannot start' ],
				[ exec.run([ 'nft', '-j' ]).ok, exec.run([ 'nft', '-j' ]).data, exec.run([ 'nft', 'x' ]).details, exec.run([ 'nft', 'y' ]).details ]);
		});
	});
});
