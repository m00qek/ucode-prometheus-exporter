'use strict';

import { describe, it, prop, gen, assert, mock, spy } from 'utest';
import { popen } from 'fs';
import * as deps from 'prometheus_exporter.deps';
import { with_mods } from 'context';
import * as commands from 'lib.commands';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

// A popen whose handles answer `outputs[command line]` = { out, status }, the
// command line taken out of exec's script: utest's fs mock closes a popen handle
// without the exit status real ucode gives.
function popen_answering(outputs, seen) {
	return function(cmd, mode) {
		push(seen, cmd);
		let o = outputs[commands.parse(cmd)?.line];
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

const CTL = '/run/unbound.ctl';

// The calls the socket mock recorded: `create`, and 'sock.<method>' on sockets.
function calls(socket, name) {
	return spy(socket).calls[name] ?? [];
}

describe('deps.socket_channel', () => {
	it('sends the message, reads the reply until the server closes, and closes the socket', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: (req) => req == 'UBCT1 stats_noreset\n' ? 'a=1\nb=2\n' : 'error\n' } }, (socket) => {
			let res = deps.socket_channel(socket).unix_request(CTL, 'UBCT1 stats_noreset\n', 1500);

			assert.match({ ok: true, data: 'a=1\nb=2\n' }, brief(res));
			assert.match([ [ socket.AF_UNIX, socket.SOCK_STREAM ] ], calls(socket, 'create'));
			assert.match([ [ { family: socket.AF_UNIX, path: CTL } ] ], calls(socket, 'sock.connect'));
			assert.match([ [ 'UBCT1 stats_noreset\n', socket.MSG_NOSIGNAL ] ], calls(socket, 'sock.send'));
			assert.match(1, length(calls(socket, 'sock.close')));
		});
	});

	it('bounds every wait by the timeout', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: '' } }, (socket) => {
			deps.socket_channel(socket).unix_request(CTL, 'x', 1500);

			assert.match([
				[ socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 1, usec: 500000 } ],
				[ socket.SOL_SOCKET, socket.SO_SNDTIMEO, { sec: 1, usec: 500000 } ],
			], calls(socket, 'sock.setopt'));
		});
	});

	it('fails with SOCKET_FAILED where the socket is missing or refuses, and closes it', () => {
		mock.inject('socket', { errors: { '/run/refusing.ctl': 'connect(): Connection refused' } }, (socket) => {
			let ch = deps.socket_channel(socket);

			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: connect(): No such file or directory` },
				brief(ch.unix_request(CTL, 'x', 1000)));
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '/run/refusing.ctl: connect(): Connection refused' },
				brief(ch.unix_request('/run/refusing.ctl', 'x', 1000)));
			assert.match([ 2, 2, 0 ], [ length(calls(socket, 'create')), length(calls(socket, 'sock.close')), length(calls(socket, 'sock.send')) ]);
		});
	});

	it('fails with SOCKET_FAILED when the reply stops coming before the server closes', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'a=1\n' }, hangs: { [CTL]: true, '/run/silent.ctl': true } }, (socket) => {
			let ch = deps.socket_channel(socket);

			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: no reply for 250 ms` }, brief(ch.unix_request(CTL, 'x', 250)));
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: '/run/silent.ctl: no reply for 1000 ms' },
				brief(ch.unix_request('/run/silent.ctl', 'x', 1000)));
			assert.match(2, length(calls(socket, 'sock.close')));
		});
	});

	it('fails with SOCKET_FAILED when no socket can be made', () => {
		mock.inject('socket', {
			strict: true,
			behavior: { create: () => null, error: () => 'socket(): Too many open files' },
		}, (socket) => {
			assert.match({ ok: false, error: 'SOCKET_FAILED', details: `${CTL}: socket(): Too many open files` },
				brief(deps.socket_channel(socket).unix_request(CTL, 'x', 1000)));
		});
	});

	it('refuses a timeout that is not a positive integer, which would wait forever', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'a=1\n' } }, (socket) => {
			let ch = deps.socket_channel(socket);

			assert.match([ 'SOCKET_FAILED', 'SOCKET_FAILED', 'SOCKET_FAILED' ],
				map([ 0, -5, '1000' ], (t) => ch.unix_request(CTL, 'x', t).error));
			assert.match([], calls(socket, 'create'));
		});
	});

	prop('gives back any reply whole, however many reads it takes',
		gen.string({ charset: 'abc=.0123456789\n', min_len: 0, max_len: 10000 }), (reply) => {
			mock.inject('socket', { strict: true, data: { [CTL]: reply } }, (socket) => {
				assert.match({ ok: true, data: reply }, brief(deps.socket_channel(socket).unix_request(CTL, 'x', 1000)));
				assert.match(1, length(calls(socket, 'sock.close')));
			});
		});
});

describe('test/proxies/socket', () => {
	it('reads a reply in chunks of the size asked, then gives EOF', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: 'abcde' } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			assert.match(true, s.connect(CTL));
			assert.match([ 'ab', 'cd', 'e', '', '' ], [ s.recv(2), s.recv(2), s.recv(2), s.recv(2), s.recv(2) ]);
		});
	});

	it('answers what was sent before the first read', () => {
		mock.inject('socket', { strict: true, data: { [CTL]: (req) => `got ${req}` } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			s.connect({ family: socket.AF_UNIX, path: CTL });
			s.send('UBCT1 ', 0);
			s.send('stats', 0);
			assert.match('got UBCT1 stats', s.recv(100));
		});
	});

	it('reports a failure by message and errno, as the real module', () => {
		mock.inject('socket', { hangs: { [CTL]: true } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			assert.match([ null, 'connect(): No such file or directory', 2 ],
				[ socket.create(socket.AF_UNIX, socket.SOCK_STREAM).connect('/run/nope.ctl'), socket.error(), socket.error(true) ]);

			s.setopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO, { sec: 0, usec: 1000 });
			s.connect(CTL);
			assert.match([ null, 'recv(): Resource temporarily unavailable', 11 ], [ s.recv(10), socket.error(), socket.error(true) ]);
		});
	});

	it('dies where the real module would block forever or the test is wrong', () => {
		mock.inject('socket', { strict: true, hangs: { [CTL]: true } }, (socket) => {
			let s = socket.create(socket.AF_UNIX, socket.SOCK_STREAM);

			s.connect(CTL);
			assert.throws(() => s.recv(10), 'would block forever');
			s.close();
			assert.throws(() => s.recv(10), 'closed socket');
			assert.throws(() => socket.create(socket.AF_UNIX, socket.SOCK_STREAM).connect('/run/other.ctl'), 'not mocked');
			assert.throws(() => socket.create(socket.AF_INET ?? 2, socket.SOCK_STREAM), 'only AF_UNIX');
		});
	});
});

describe('deps.exec_channel', () => {
	it('runs an allowed program with quoted arguments, under the watchdog with the default seconds', () => {
		let seen = [];
		let ch = deps.exec_channel(popen_answering({ "'nft' '--json' 'list counters'": { out: '{}', status: 0 } }, seen), [ 'nft' ]);

		assert.match({ ok: true, data: '{}' }, brief(ch.run([ 'nft', '--json', 'list counters' ])));
		assert.match([ { seconds: 5, line: "'nft' '--json' 'list counters'" } ], map(seen, commands.parse));
		assert.match(deps.EXEC_SECONDS, 5);
	});

	it('refuses a program not in the allowlist, without running anything', () => {
		let seen = [];
		let ch = deps.exec_channel(popen_answering({}, seen), [ 'nft' ]);

		assert.match({ ok: false, error: 'COMMAND_NOT_ALLOWED', details: 'sh' }, brief(ch.run([ 'sh', '-c', 'reboot' ])));
		assert.match([], seen);
	});

	it('fails on a non-zero exit status, and on a program that cannot start', () => {
		let ch = deps.exec_channel(popen_answering({ "'mmcli' '-L'": { out: '', status: 1 } }, []), [ 'mmcli', 'nope' ]);

		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'mmcli: exit status 1' }, brief(ch.run([ 'mmcli', '-L' ])));
		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'nope: cannot start' }, brief(ch.run([ 'nope' ])));
		assert.match([ { status: 1 }, { status: null } ], [ ch.run([ 'mmcli', '-L' ]).data, ch.run([ 'nope' ]).data ]);
	});

	it('fails with COMMAND_TIMEOUT when the watchdog killed the program', () => {
		let ch = deps.exec_channel(popen_answering({ "'ubnt-manager' '-l'": { out: 'partial', status: deps.EXEC_KILLED } }, []), [ 'ubnt-manager' ]);
		let res = ch.run([ 'ubnt-manager', '-l' ]);

		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'ubnt-manager: still running after 5 s, killed' }, brief(res));
		assert.match({ status: null, timed_out: true }, res.data);
	});

	// clock() gives these, in ms from 0, one per call.
	function clock_at(times) {
		let i = 0;
		return () => { let ms = times[min(i++, length(times) - 1)]; return [ 1000 + ms / 1000, (ms % 1000) * 1000000 ]; };
	}

	it('spends one allowance of seconds across the programs it runs, from the first', () => {
		let seen = [];
		let ch = deps.exec_channel(popen_answering({ "'mmcli' '-L'": { out: '', status: 0 } }, seen), [ 'mmcli' ], 5,
			clock_at([ 0, 3500, 4999, 5000, 9000 ]));

		let ran = map([ 1, 2, 3, 4, 5 ], () => ch.run([ 'mmcli', '-L' ]));

		assert.match([ 5, 2, 1 ], map(seen, (s) => commands.parse(s).seconds));
		assert.match([ true, true, true, false, false ], map(ran, (r) => r.ok));
		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: "mmcli: not run, the collector's 5 s for commands are spent" }, brief(ran[3]));
		assert.match({ status: null, timed_out: true }, ran[4].data);
	});

	it('gives the seconds it is made with', () => {
		let seen = [];
		deps.exec_channel(popen_answering({}, seen), [ 'nft' ], 12, clock_at([ 0 ])).run([ 'nft' ]);

		assert.match([ 12 ], map(seen, (s) => commands.parse(s).seconds));
	});

	prop('quotes any argument so a real shell passes it on unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (arg) => {
		let p = popen("printf '%s' " + deps.shell_quote(arg), 'r');
		let out = p.read('all');
		p.close();

		assert.match(arg, out);
	});
});

function seconds_since(t) {
	let now = clock(true);
	return (now[0] - t[0]) + (now[1] - t[1]) / 1000000000.0;
}

// Real programs under the real watchdog script, through /bin/sh.
describe('deps.exec_channel, running programs', () => {
	it('gives a program\'s whole output, without its stderr, and its exit status', () => {
		let ch = deps.exec_channel(popen, [ 'sh' ]);
		let big = ch.run([ 'sh', '-c', 'i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done' ]);

		assert.match({ ok: true, data: 'out\n' }, brief(ch.run([ 'sh', '-c', 'echo out; echo err >&2' ])));
		assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'sh: exit status 3' }, brief(ch.run([ 'sh', '-c', 'exit 3' ])));
		assert.match([ true, 220000 ], [ big.ok, length(big.data) ]);
	});

	it('gives the shell\'s 127 for a program that is not there', () => {
		assert.match({ status: 127 }, deps.exec_channel(popen, [ 'prometheus-exporter-no-such-program' ]).run([ 'prometheus-exporter-no-such-program' ]).data);
	});

	it('does not hold a program that is done to its seconds', () => {
		let t = clock(true);
		let res = deps.exec_channel(popen, [ 'printf' ], 5).run([ 'printf', '%s', 'x' ]);

		assert.match({ ok: true, data: 'x' }, brief(res));
		assert.match(true, seconds_since(t) < 1);
	});

	it('kills a program still running when its seconds are spent, and what it started', () => {
		let t = clock(true);
		let res = deps.exec_channel(popen, [ 'sh' ], 1).run([ 'sh', '-c', 'echo partial; sleep 3061 & x=$(sh -c "sleep 3062; :"); wait' ]);

		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'sh: still running after 1 s, killed' }, brief(res));
		assert.match({ status: null, timed_out: true }, res.data);
		assert.match(true, seconds_since(t) < 3);
		assert.match([], commands.running('sleep 306'));
	});

	it('does not start a program once the seconds are spent', () => {
		let ch = deps.exec_channel(popen, [ 'sleep', 'printf' ], 1);

		assert.match('COMMAND_TIMEOUT', ch.run([ 'sleep', '3063' ]).error);
		assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: "printf: not run, the collector's 1 s for commands are spent" },
			brief(ch.run([ 'printf', 'x' ])));
		assert.match([], commands.running('sleep 3063'));
	});

	prop('passes any argument on unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (arg) => {
		assert.match({ ok: true, data: arg }, brief(deps.exec_channel(popen, [ 'printf' ]).run([ 'printf', '%s', arg ])));
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

	it('names the collector in what it logs, and has no log without the exporter\'s', () => {
		with_mods({}, (mods) => {
			let seen = [];
			deps.session({ ...mods, log: (m) => push(seen, m) }).for({ name: 'textfile', needs: [ 'log' ] }).data.log('skipped a.prom');

			assert.match([ "collector 'textfile': skipped a.prom" ], seen);
			assert.match('NEED_MISSING', deps.session(mods).for({ name: 'textfile', needs: [ 'log' ] }).error);
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
		assert.match([ 'exec', 'fs', 'log', 'nl80211', 'rtnl', 'socket', 'time', 'ubus', 'uci' ], sort([ ...deps.NEEDS ]));
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

	// ucode-mod-socket exports no `const`, so its shim compiles and it loads.
	it('loads socket by name: the functions and constants socket_channel uses', () => {
		let m = deps.load_socket();

		assert.match([ 'function', 'function' ], [ type(m.create), type(m.error) ]);
		assert.match([ 'int', 'int', 'int', 'int', 'int', 'int' ],
			map([ 'AF_UNIX', 'SOCK_STREAM', 'SOL_SOCKET', 'SO_RCVTIMEO', 'SO_SNDTIMEO', 'MSG_NOSIGNAL' ], (k) => type(m[k])));
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

	it('fakes a program that hangs', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { hangs: true } }) }, (mods) => {
			let res = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec.run([ 'nft', '-j' ]);

			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'nft: still running after 5 s, killed' }, brief(res));
		});
	});

	it('runs a real program in a fake one\'s place, with its own seconds', () => {
		with_mods({ fs: commands.fs({ [commands.line([ 'nft', '-j' ])]: { run: [ 'sh', '-c', 'sleep 3064' ], seconds: 1 } }) }, (mods) => {
			let t = clock(true);
			let res = deps.session(mods).for({ needs: [ 'exec' ], commands: [ 'nft' ] }).data.exec.run([ 'nft', '-j' ]);

			assert.match([ 'COMMAND_TIMEOUT', true ], [ res.error, seconds_since(t) < 3 ]);
			assert.match([], commands.running('sleep 3064'));
		});
	});

	it('takes apart the scripts exec runs, and nothing else', () => {
		assert.match({ seconds: 7, line: "'a b' 'c\n'" }, commands.parse(deps.exec_script([ 'a b', 'c\n' ], 7)));
		assert.match([ null, null ], [ commands.parse("'nft' 2>/dev/null"), commands.parse('set -- 1 x') ]);
	});
});
