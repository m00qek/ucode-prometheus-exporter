'use strict';

import { describe, it, assert, mock } from 'utest';
import * as rpc from 'prometheus.exporter.rpc';
import * as config from 'prometheus.exporter.config';
import * as Result from 'prometheus.exporter.result';
import * as ledger from 'prometheus.exporter.ledger';
import * as crypt from 'prometheus.exporter.crypt';
import { NAME, ROUTER_INTERFACES, LOADAVG, WIFI, TEXTFILE, WIREGUARD, FAILING, IDLE, with_sys } from 'lib.rpc';

describe('rpc.hash_password', () => {
	function hash_password(args, random) {
		return rpc.hash_password({ random: random ?? ((n) => substr('abcdefghijklmnopqrstuvwxyz', 0, n)) }, args);
	}

	it('gives a fresh SHA-512-crypt hash of the password, which the config takes', () => {
		let res = hash_password({ password: 'secret' });

		assert.match([ 'hash' ], keys(res));
		assert.match(true, crypt.verify('secret', res.hash));
		assert.match(true, config.datatype('crypt').check(res.hash));
	});

	it('salts each hash with the random bytes it gets', () => {
		let a = hash_password({ password: 'secret' }, (n) => substr('aaaaaaaaaaaaaaaa', 0, n));
		let b = hash_password({ password: 'secret' }, (n) => substr('bbbbbbbbbbbbbbbb', 0, n));

		assert.match(false, a.hash == b.hash);
	});

	it('refuses a password it does not take, without saying it', () => {
		assert.match([
			{ error: rpc.ARGS_INVALID, message: 'password: expected a password' },
			{ error: rpc.ARGS_INVALID, message: 'password: expected a password' },
			{ error: rpc.ARGS_INVALID, message: 'password: expected a password without control characters' },
		], [
			hash_password({}),
			hash_password({ password: 42 }),
			hash_password({ password: 'a\tb' }),
		]);
	});

	it('says when there is no randomness', () => {
		assert.match({ error: 'CONFIG_INVALID', message: 'CONFIG_INVALID (no random bytes for a salt)' },
			hash_password({ password: 'secret' }, () => null));
	});

	it('is served on a sys without collectors', () => {
		let opts = [];
		let m = rpc.methods(function(o) { push(opts, o); return { random: (n) => substr('abcdefghijklmnop', 0, n) }; }, null);
		let res = m.hash_password.call({ args: { password: 'secret' } });

		assert.match([ [ { collectors: false } ], true ], [ opts, crypt.verify('secret', res.hash) ]);
	});
});

describe('rpc.password and rpc.set_password', () => {
	const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';

	// A sys whose uci holds `hash` in the hash's config (none when null, and no
	// config at all when `file` is false), whose fs records what it writes, and
	// whose ubus records the events sent.
	function with_hash_sys(hash, file, cb) {
		let data = (file === false) ? {} : { [config.AUTH_CONFIG]: (hash != null) ? { main: { '.type': config.AUTH_TYPE, auth_password: hash } } : {} };
		let seen = { written: [], events: [] };

		mock.inject('uci', { data }, (uci) => {
			let writer = uci.cursor();
			let sys = {
				uci: uci.cursor(),
				uci_writer: () => writer,
				random: (n) => substr('abcdefghijklmnopqrstuvwxyz', 0, n),
				fs: {
					stat: (p) => (p == rpc.AUTH_FILE && file !== false) ? { type: 'file' } : null,
					writefile: function(p, text) { push(seen.written, [ p, text ]); return length(text); },
					chmod: function(p, mode) { push(seen.written, [ p, mode ]); return true; },
				},
				ubus: { call: function(obj, method, args) { push(seen.events, [ obj, method, args ]); return Result.ok(null); } },
			};

			cb(sys, seen, () => writer.get(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password'));
		});
	}

	it('says whether a hash is saved, and never which', () => {
		for (let t in [ [ HASH, true ], [ null, false ], [ '', false ] ])
			with_hash_sys(t[0], true, (sys) => {
				let res = rpc.password(sys);

				assert.match({ saved: t[1] }, res, t[0]);
				assert.match(-1, index(sprintf('%J', res), HASH));
			});
	});

	it('hashes a password, saves the hash apart, and asks procd for the reload a commit of it brings', () => {
		with_hash_sys(HASH, true, (sys, seen, saved) => {
			let res = rpc.set_password(sys, { password: 'secret' });

			assert.match({ saved: true }, res);
			assert.match([ true, true ], [ crypt.verify('secret', saved()), saved() != HASH ]);
			assert.match([ [ 'service', 'event', { type: rpc.CONFIG_CHANGE, data: { package: config.AUTH_CONFIG } } ] ], seen.events);
			assert.match([], seen.written);
		});
	});

	it('removes the saved hash for an empty password', () => {
		with_hash_sys(HASH, true, (sys, seen, saved) => {
			assert.match([ { saved: false }, null ], [ rpc.set_password(sys, { password: '' }), saved() ]);
			assert.match(1, length(seen.events));
		});
	});

	it('refuses a password it does not take, saving nothing and asking for no reload', () => {
		with_hash_sys(HASH, true, (sys, seen, saved) => {
			assert.match([
				{ error: rpc.ARGS_INVALID, message: 'password: expected a password' },
				{ error: rpc.ARGS_INVALID, message: 'password: expected a password without control characters' },
			], [ rpc.set_password(sys, {}), rpc.set_password(sys, { password: 'a\tb' }) ]);
			assert.match([ HASH, [] ], [ saved(), seen.events ]);
		});
	});

	it('writes the config again, mode 0600, when it is gone', () => {
		with_hash_sys(null, false, (sys, seen) => {
			rpc.set_password(sys, { password: 'secret' });

			assert.match([ [ rpc.AUTH_FILE, `config ${config.AUTH_TYPE} '${config.AUTH_SECTION}'\n` ], [ rpc.AUTH_FILE, 0o600 ] ], seen.written);
		});
	});

	it('is served, reading on a sys without collectors, and closes its ubus channel', () => {
		let opts = [];
		let closed = 0;
		let m = rpc.methods(function(o) {
			push(opts, o);
			return { uci: { get: () => HASH }, ubus: { close: () => closed++ } };
		}, null);

		assert.match([ { saved: true }, [ { collectors: false } ] ], [ m.password.call({ args: {} }), opts ]);
		assert.match({ error: rpc.ARGS_INVALID, message: 'password: expected a password' }, m.set_password.call({ args: {} }));
		assert.match(1, closed);
	});
});

describe('rpc.service', () => {
	const RUNNING = { [NAME]: { instances: { instance1: { running: true,
		command: [ '/usr/sbin/uhttpd', '-f', '-p', '192.168.1.1:9100', '-p', '[fd00::1]:9100' ] } } } };

	function service(own, ubus, links, hash) {
		let out;

		with_sys(own, { ubus, links, hash }, (sys) => {
			out = rpc.service(sys);
		});

		return out;
	}

	it('says a running instance runs, and where it listens', () => {
		assert.match({
			service: { enabled: true, boot: true, running: true, error: null, auth: false, compress: true },
			listen: [ 'http://192.168.1.1:9100/metrics', 'http://[fd00::1]:9100/metrics' ],
		}, service({}, { data: { 'service:list': RUNNING } }, [ `${rpc.RC_DIR}/S60${NAME}` ]));
	});

	it('says a service without instances is not running, and listens nowhere', () => {
		assert.match({
			service: { enabled: false, boot: false, running: false, error: null, auth: false, compress: true },
			listen: [],
		}, service({ main: { '.type': NAME, enabled: '0' } }, { data: { 'service:list': {} } }, []));
	});

	it('counts a stopped instance as not running', () => {
		let stopped = { [NAME]: { instances: { instance1: { running: false, command: [ 'uhttpd', '-p', '9100' ] } } } };

		let res = service({}, { data: { 'service:list': stopped } });

		assert.match([ false, [] ], [ res.service.running, res.listen ]);
	});

	it('counts uhttpd alone, not the watch instance beside it', () => {
		let watching = { [NAME]: { instances: {
			instance1: { running: false, command: [ '/usr/sbin/uhttpd', '-p', '9100' ] },
			watch: { running: true, command: [ `/usr/libexec/${NAME}/watch.uc`, '/var/lib/unbound' ] },
		} } };

		let res = service({}, { data: { 'service:list': watching } });

		assert.match([ false, [] ], [ res.service.running, res.listen ]);
	});

	it('says whether a scrape logs in and is compressed, and never the hash', () => {
		let hash = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
		let res = service({ main: { '.type': NAME, auth_user: 'prom', cert: '/etc/ssl/c', key: '/etc/ssl/k', compress: '0' } },
			{ data: { 'service:list': {} } }, [], hash);

		assert.match([ true, false ], [ res.service.auth, res.service.compress ]);
		assert.match(-1, index(sprintf('%J', res), hash));
	});

	it('says when procd cannot be asked, and when the main section is invalid', () => {
		assert.match({
			service: { enabled: null, boot: false, running: null, error: 'UBUS_CALL_FAILED (service list: Not found)', auth: null, compress: true },
			listen: [],
		}, service({ main: { '.type': NAME, enabled: 'maybe' } }, { errors: { 'service:list': 'Not found' } }));
	});
});

describe('rpc.scrape_report and rpc.status', () => {
	it('runs each enabled collector once, and says how it did', () => {
		with_sys({ textfile: { '.type': 'collector', enabled: '0' } }, { collectors: [ LOADAVG, FAILING, TEXTFILE ] }, (sys) => {
			assert.match([
				{ name: 'loadavg', id: 'loadavg', title: 'loadavg', enabled: true, success: true, observing: true, reason: null,
					duration: 0.005, error: null, mounts: [], service: null },
				{ name: 'openwrt', id: 'openwrt', title: 'openwrt', enabled: true, success: false, observing: true, reason: null,
					duration: 0.005, error: 'UBUS_CALL_FAILED (system board: Not found)', mounts: [], service: null },
				{ name: 'textfile', id: 'textfile', title: 'textfile', enabled: false, success: null, observing: null, reason: null,
					duration: null, error: null, mounts: [], service: null },
			], rpc.scrape_report(sys));
		});
	});

	// The ledger of the service's running instance.
	it('says what the service\'s scrapes found of each collector, and still runs a quarantined one', () => {
		let l = { ...ledger.empty(), scrapes: 40, c: {
			loadavg: { d: 0.01, n: 3, late: 40 },
			openwrt: { d: 6, n: 1, q: 42, cd: 4, why: 'COLLECTOR_OVERRUN (took 6.00 s, over its budget of 5 s)' },
		} };

		with_sys({}, { collectors: [ LOADAVG, FAILING ], ledger: l }, (sys) => {
			let r = rpc.scrape_report(sys);

			assert.match([
				{ estimate: 0.01, quarantined: false, reason: null, retry_in: null, late: 0 },
				{ estimate: 6, quarantined: true, reason: 'COLLECTOR_OVERRUN (took 6.00 s, over its budget of 5 s)', retry_in: 3, late: null },
			], map(r, (c) => c.service));
			assert.match([ true, false ], map(r, (c) => c.success));
		});
	});

	it('says a collector with nothing to observe succeeded, and why it observes nothing', () => {
		with_sys({}, { collectors: [ IDLE ] }, (sys) => {
			let c = rpc.scrape_report(sys)[0];

			assert.match({ success: true, observing: false, reason: 'dnsmasq is disabled', error: null },
				{ success: c.success, observing: c.observing, reason: c.reason, error: c.error });
		});
	});

	it('gives the mounts of an enabled collector', () => {
		with_sys({}, { collectors: [ WIREGUARD ], ubus: { data: { 'wireguard:status': {} } } }, (sys) => {
			assert.match([ '/etc/config/network' ], rpc.scrape_report(sys)[0].mounts);
		});
	});

	it('tells a collector that cannot be configured from one that failed', () => {
		with_sys({ wifi: { '.type': 'collector', stations: 'maybe' } }, { collectors: [ WIFI ] }, (sys) => {
			assert.match('CONFIG_INVALID (stations: expected a boolean, got "maybe")', rpc.scrape_report(sys)[0].error);
		});
	});

	it('puts the service and the scrape together', () => {
		with_sys({}, { collectors: [ LOADAVG ], ubus: { data: { 'service:list': {} } } }, (sys) => {
			let res = rpc.status(sys);

			assert.match([ 'collectors', 'jailed', 'listen', 'service' ], sort(keys(res)));
			assert.match([ 'loadavg' ], map(res.collectors, (c) => c.name));
			assert.match(false, res.jailed);
		});
	});

	it('scrapes in the service\'s jail when sys can, and says it did', () => {
		with_sys({}, { collectors: [ LOADAVG ], ubus: { data: { 'service:list': {} } } }, (sys) => {
			let asked = [];

			sys.trial = function(chosen, here) {
				push(asked, map(chosen, (c) => c.id));
				return { jailed: true, runs: [ { name: 'loadavg', id: 'loadavg', duration: 0.01, samples: 3, result: { ok: true } } ] };
			};

			let res = rpc.status(sys);

			assert.match([ [ [ 'loadavg' ] ], true ], [ asked, res.jailed ]);
			assert.match({ name: 'loadavg', success: true, observing: true, duration: 0.01, error: null },
				{ name: res.collectors[0].name, success: res.collectors[0].success, observing: res.collectors[0].observing,
					duration: res.collectors[0].duration, error: res.collectors[0].error });
		});
	});
});

describe('rpc.cached_probe', () => {
	// fs over modules `sigs` ({ id: 'inode:size:mtime' }), whose helper prints `out`.
	function fs_of(sigs, out, cmds) {
		return {
			stat: function(p) {
				let id = match(p, /\/([a-z0-9_]+)\.uc$/)[1];
				let s = sigs[id];

				return s ? { inode: split(s, ':')[0], size: split(s, ':')[1], mtime: split(s, ':')[2] } : null;
			},
			popen: function(cmd) { push(cmds, cmd); return { read: () => out, close: () => 0 }; },
		};
	}

	it('asks the helper of the modules it has not seen, once per version of each', () => {
		let cmds = [];
		let sigs = { a: '1:10:100', b: '2:20:200' };
		let out = '{"a":{"ok":true},"b":{"ok":false,"hung":true,"error":"still loading after 5 s: stopped"}}';
		let probe = rpc.cached_probe(fs_of(sigs, out, cmds), '/c', '/probe.uc');

		assert.match({ a: { ok: true }, b: { ok: false, hung: true, error: 'still loading after 5 s: stopped' } }, probe([ 'a', 'b' ]));
		assert.match({ a: { ok: true }, b: { ok: false, hung: true, error: 'still loading after 5 s: stopped' } }, probe([ 'a', 'b' ]));
		sigs.b = '3:21:300';
		probe([ 'a', 'b' ]);
		assert.match([ '/probe.uc a b 2>/dev/null', '/probe.uc b 2>/dev/null' ], cmds);
	});

	it('takes a module the helper says nothing of as not loaded, and asks again next time', () => {
		let cmds = [];
		let probe = rpc.cached_probe(fs_of({ a: '1:1:1' }, 'not json', cmds), '/c', '/probe.uc');

		assert.match({ a: { ok: false, hung: false, error: '/probe.uc said nothing of it' } }, probe([ 'a' ]));
		probe([ 'a' ]);
		assert.match(2, length(cmds));
	});
});

// status runs a full scrape, as root, for up to 60 s: a read-only login
// that calls it again and again must not pile them up.
describe('rpc.shared_json, and status', () => {
	function setup(no_process) {
		let replies = [], commands = [], watched = [];
		let io = {
			popen: function(cmd) {
				push(commands, cmd);
				return no_process ? null : { read: () => sprintf('{ "n": %d }', length(commands)), close: () => 0 };
			},
			watch: (handle, cb) => push(watched, cb),
		};
		let req = (name) => ({ defer: () => `deferred ${name}`, reply: (data) => push(replies, [ name, data ]) });

		return { io, req, replies, commands, watched };
	}

	it('runs one at a time: a call while one runs waits for it, and gets its reply', () => {
		let t = setup();
		let m = rpc.methods(() => die('no sys'), t.io);

		assert.match([ 'deferred a', 'deferred b', 'deferred c' ], [ m.status.call(t.req('a')), m.status.call(t.req('b')), m.status.call(t.req('c')) ]);
		assert.match([ 1, 1 ], [ length(t.commands), length(t.watched) ]);
		t.watched[0]();
		assert.match([ [ 'a', { n: 1 } ], [ 'b', { n: 1 } ], [ 'c', { n: 1 } ] ], t.replies);

		// Done, the next call runs again.
		m.status.call(t.req('d'));
		t.watched[1]();
		assert.match([ 2, [ 'd', { n: 2 } ] ], [ length(t.commands), t.replies[-1] ]);
	});

	it('replies to the others when one of them is gone', () => {
		let t = setup();
		let run = { waiting: null };
		let gone = { defer: () => 'deferred', reply: () => die('Reply has already been sent') };

		rpc.shared_json(run, gone, t.io, 'x', 'x');
		rpc.shared_json(run, t.req('b'), t.io, 'x', 'x');
		t.watched[0]();
		assert.match([ [ [ 'b', { n: 1 } ] ], null ], [ t.replies, run.waiting ]);
	});

	it('runs again after a command that could not start', () => {
		let t = setup(true);
		let run = { waiting: null };

		assert.match({ error: rpc.STATUS_FAILED, message: 'cannot run x' }, rpc.shared_json(run, t.req('a'), t.io, 'x', 'x'));
		assert.match(null, run.waiting);
	});
});

describe('rpc.deferred_json', () => {
	// A request that records its reply, and io whose command prints `out`.
	function run(out, opts) {
		let replies = [];
		let commands = [];
		let req = {
			defer: () => 'deferred',
			reply: function(data) {
				if (opts?.replied)
					die('Reply has already been sent');
				push(replies, data);
			},
		};
		let io = {
			popen: function(cmd) {
				push(commands, cmd);
				return opts?.no_process ? null : { read: () => out, close: () => 0 };
			},
			watch: (handle, cb) => cb(),
		};
		let returned = rpc.deferred_json(req, io, '/usr/libexec/x.uc 2>/dev/null');

		return { returned, replies, commands };
	}

	it('defers the request, and replies with what the command prints', () => {
		assert.match({ returned: 'deferred', replies: [ { ok: true } ], commands: [ '/usr/libexec/x.uc 2>/dev/null' ] },
			run('{ "ok": true }\n'));
	});

	it('replies with an error when the command prints no object', () => {
		for (let out in [ '', 'oops', '[ 1 ]' ])
			assert.match([ { error: rpc.STATUS_FAILED, message: '/usr/libexec/x.uc 2>/dev/null printed no reply' } ], run(out).replies);
	});

	it('answers at once when the command cannot start', () => {
		assert.match({ error: rpc.STATUS_FAILED, message: 'cannot run /usr/libexec/x.uc 2>/dev/null' },
			run('', { no_process: true }).returned);
	});

	it('survives a request rpcd has answered already', () => {
		assert.match('deferred', run('{}', { replied: true }).returned);
	});
});

describe('rpc.interfaces', () => {
	function interfaces(ubus, own) {
		let out;

		with_sys(own ?? {}, { ubus }, (sys) => {
			out = rpc.interfaces(sys);
		});

		return out;
	}

	it('lists netifd\'s logical interfaces, their names and protocols only, in its order', () => {
		assert.match({ interfaces: [
			{ name: 'guest', proto: 'static' },
			{ name: 'iot', proto: 'static' },
			{ name: 'lan2playground', proto: 'wireguard' },
			{ name: 'loopback', proto: 'static' },
			{ name: 'main', proto: 'static' },
			{ name: 'mgmt', proto: 'static' },
			{ name: 'wan', proto: 'dhcp' },
			{ name: 'wan6', proto: 'dhcpv6' },
			{ name: 'wg_mesh', proto: 'wireguard' },
		] }, interfaces({ data: { 'network.interface:dump': ROUTER_INTERFACES } }));
	});

	it('asks netifd once, for its dump', () => {
		with_sys({}, { ubus: { data: { 'network.interface:dump': { interface: [] } } } }, (sys) => {
			let calls = [];
			let channel = sys.ubus;

			sys.ubus = {
				call: function(o, m, a) { push(calls, [ o, m, a ]); return channel.call(o, m, a); },
				close: () => channel.close(),
			};
			rpc.interfaces(sys);
			assert.match([ [ 'network.interface', 'dump', {} ] ], calls);
		});
	});

	it('skips an entry without a name, and gives a missing protocol as null', () => {
		assert.match({ interfaces: [ { name: 'lan', proto: null }, { name: 'wan', proto: 'dhcp' } ] }, interfaces({ data: {
			'network.interface:dump': { interface: [
				{ interface: 'lan' }, { proto: 'static' }, { interface: '', proto: 'static' }, null, 'x', { interface: 7 },
				{ interface: 'wan', proto: 'dhcp', 'ipv4-address': [ { address: '192.0.2.1', mask: 24 } ] },
			] },
		} }));
	});

	it('gives none for a reply without interfaces', () => {
		for (let reply in [ {}, { interface: null } ])
			assert.match({ interfaces: [] }, interfaces({ data: { 'network.interface:dump': reply } }));
	});

	it('says when netifd cannot be asked', () => {
		assert.match({ error: 'UBUS_CALL_FAILED', message: 'UBUS_CALL_FAILED (network.interface dump: Not found)' },
			interfaces({ errors: { 'network.interface:dump': 'Not found' } }));
	});

	it('reads neither uci nor files, so /etc/config/network stays unread', () => {
		with_sys({}, { ubus: { data: { 'network.interface:dump': ROUTER_INTERFACES } } }, (sys) => {
			let refuse = () => die('read');

			sys.uci = { load: refuse, get: refuse, get_all: refuse, foreach: refuse, sections: refuse };
			sys.fs = { stat: refuse, glob: refuse, readfile: refuse, open: refuse, lsdir: refuse };
			assert.match(9, length(rpc.interfaces(sys).interfaces));
		});
	});
});

describe('rpc.methods', () => {
	it('serves collectors, validate and status, each on a fresh sys', () => {
		let made = 0;
		let commands = [];
		let sys = { collectors: [], skipped: [], fs: { glob: () => [], readfile: () => null } };
		let m = rpc.methods(function() { made++; return sys; }, {
			popen: function(cmd) { push(commands, cmd); return null; },
			watch: () => null,
		});

		assert.match([ 'collectors', 'hash_password', 'interfaces', 'password', 'set_password', 'status', 'validate' ], sort(keys(m)));
		assert.match({ collectors: [], skipped: [] }, m.collectors.call({ args: {} }));
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, m.validate.call({ args: { main: { listen_port: '80' } } }));
		assert.match(2, made);
		m.status.call({ args: {}, defer: () => null });
		assert.match([ rpc.STATUS_COMMAND ], commands);
		assert.match(0, index(rpc.STATUS_COMMAND, `set -- 60 '${rpc.STATUS_HELPER}'\n`));
	});

	it('serves interfaces on a sys without collectors, and closes its ubus channel', () => {
		let opts = [];
		let closed = 0;
		let m = rpc.methods(function(o) {
			push(opts, o);
			return {
				ubus: {
					call: (obj, method) => Result.ok({ interface: [ { interface: 'lan', proto: 'static' } ] }),
					close: () => closed++,
				},
			};
		}, null);

		assert.match({ interfaces: [ { name: 'lan', proto: 'static' } ] }, m.interfaces.call({ args: {} }));
		assert.match([ [ { collectors: false } ], 1 ], [ opts, closed ]);
	});

	it('declares the arguments rpcd checks', () => {
		let m = rpc.methods(() => null, null);

		assert.match([ {}, { main: {}, collectors: {} }, {}, {}, { password: '' } ],
			[ m.collectors.args, m.validate.args, m.status.args, m.interfaces.args, m.hash_password.args ]);
	});

	it('names the object and the helper after the exporter\'s package', () => {
		assert.match([ NAME, `/usr/libexec/${NAME}/rpc-status.uc` ], [ rpc.OBJECT, rpc.STATUS_HELPER ]);
	});
});
