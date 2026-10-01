'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as rpc from 'prometheus_exporter.rpc';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import * as Result from 'prometheus_exporter.result';
import * as fixtures from 'lib.fixtures';
import { with_mods } from 'context';

const NAME = config.NAME;
// Read before any mock is active: fs is mocked too.
const ROUTER_INTERFACES = fixtures.ubus('caju-router', 'network.interface', 'dump');
const PACKAGE = config.PACKAGE;
const DIR = '/collectors';
const APK = '/apk';

// A collector as the loader returns it. Options may be given as bare defaults:
// they get the help the loader requires.
function collector(name, meta, collect) {
	let options = {};

	for (let k, v in meta?.options ?? {})
		options[k] = (type(v) == 'object') ? v : { default: v, help: `The ${k} option.` };

	let res = loader.validate(loader.id_of(name), {
		meta: { name, title: name, help: `The ${name} test collector.`, needs: [], ...meta, options },
		collect: collect ?? (() => Result.ok()),
	});

	if (!res.ok)
		die(Result.describe(res));

	return res.data;
}

const LOADAVG = collector('loadavg', { needs: [ 'fs' ] });
const WIFI = collector('wifi', { needs: [ 'ubus' ], options: { stations: true } });
const TEXTFILE = collector('textfile', { needs: [ 'fs' ], options: { directory: '/var/prometheus' }, paths: [ '{directory}' ] });
const WIREGUARD = collector('wireguard', { needs: [ 'ubus', 'uci' ], configs: [ 'network' ] });
const NFT = collector('nft-counters', { needs: [ 'exec' ], commands: [ 'nft' ] });
const SAMPLER = collector('sampler', { needs: [], options: { retries: 3, verbose: false, label: 'x' } });
const FAILING = collector('openwrt', { needs: [] }, () => Result.err('UBUS_CALL_FAILED', 'system board: Not found'));
const ALL = [ LOADAVG, WIFI, TEXTFILE, WIREGUARD, NFT, SAMPLER ];

// apk's file lists: loadavg in the base package, wifi and textfile in their own.
const LISTS = {
	[`${APK}/${PACKAGE}.list`]: `/usr/bin/${NAME}\n${DIR}/loadavg.uc\n`,
	[`${APK}/${PACKAGE}-wifi.list`]: `${DIR}/wifi.uc\n`,
	[`${APK}/${PACKAGE}-textfile.list`]: `${DIR}/textfile.uc\n`,
};

// A filesystem of these regular files and apk lists; glob matches the lists and
// the start links of `links`.
function filesystem(files, links) {
	return {
		stat: (p) => (p in (files ?? [])) ? { type: 'file' } : null,
		readfile: (p) => LISTS[p],
		glob: function(pattern) {
			if (pattern == `${APK}/${PACKAGE}*.list`)
				return sort(keys(LISTS));
			if (pattern == `${rpc.RC_DIR}/S*${NAME}`)
				return links ?? [];
			die(`unexpected glob ${pattern}`);
		},
	};
}

// A sys over the mocks: `own` is the exporter's config, cfg.ubus the ubus mock's,
// cfg.files and cfg.links what the filesystem has.
function with_sys(own, cfg, cb) {
	with_mods({ uci: { data: { [NAME]: own, network: {} } }, ubus: cfg.ubus ?? {} }, function(mods) {
		let quiet = () => null;
		let tick = 0;
		let sys = {
			uci: mods.uci.cursor(),
			fs: filesystem(cfg.files, cfg.links),
			path: jail.PATH,
			dir: DIR,
			apk: APK,
			collectors: cfg.collectors ?? ALL,
			skipped: cfg.skipped ?? [],
			env: {
				session: () => deps.session({ ...mods, log: quiet }),
				// Each run takes 5 ms.
				clock: () => [ 0, (tick++ % 2) * 5000000 ],
				log: quiet,
			},
			ubus: deps.ubus_channel(mods.ubus.connect),
		};

		cb(sys);
		sys.ubus.close();
	});
}

function entry(sys, name) {
	return filter(rpc.collectors(sys).collectors, (c) => c.name == name)[0];
}

describe('rpc.option_spec', () => {
	it('takes a bare default, typed by it, with no help or datatype', () => {
		assert.match([
			{ name: 'stations', type: 'bool', default: true, help: null, datatype: null },
			{ name: 'retries', type: 'int', default: 3, help: null, datatype: null },
			{ name: 'directory', type: 'string', default: '/var/prometheus', help: null, datatype: null },
		], [
			rpc.option_spec('stations', true),
			rpc.option_spec('retries', 3),
			rpc.option_spec('directory', '/var/prometheus'),
		]);
	});

	it('takes { default, help, datatype }, and leaves out an empty help or datatype', () => {
		assert.match([
			{ name: 'directory', type: 'string', default: '/var/prometheus', help: 'Where the .prom files are.', datatype: 'directory' },
			{ name: 'fields', type: 'string', default: '^pg', help: null, datatype: 'regex' },
			{ name: 'stations', type: 'bool', default: false, help: null, datatype: null },
		], [
			rpc.option_spec('directory', { default: '/var/prometheus', help: 'Where the .prom files are.', datatype: 'directory' }),
			rpc.option_spec('fields', { default: '^pg', help: '', datatype: 'regex' }),
			rpc.option_spec('stations', { default: false }),
		]);
	});

	prop('gives the same spec for a bare default and the object that holds only it',
		gen.oneof(gen.bool(), gen.int(-1000, 1000), gen.string({ min_len: 0, max_len: 12 })), (v) => {
			assert.match(rpc.option_spec('o', { default: v }), rpc.option_spec('o', v));
			assert.match({ name: 'o', type: type(v), default: v, help: null, datatype: null }, rpc.option_spec('o', v));
		});
});

describe('rpc.options_of and rpc.title_of', () => {
	it('lists the options in the order the collector declares them, in either shape', () => {
		let meta = { options: { stations: true, directory: { default: '/x', help: 'Dir.', datatype: 'directory' }, retries: 3 } };

		assert.match([ 'stations', 'directory', 'retries' ], map(rpc.options_of(meta), (o) => o.name));
		assert.match([ null, 'directory', null ], map(rpc.options_of(meta), (o) => o.datatype));
		assert.match([], rpc.options_of({}));
	});

	it('gives meta.title, or the name without one', () => {
		assert.match([ 'Wi-Fi', 'wifi', 'wifi' ], [
			rpc.title_of({ name: 'wifi', title: 'Wi-Fi' }),
			rpc.title_of({ name: 'wifi' }),
			rpc.title_of({ name: 'wifi', title: '' }),
		]);
	});
});

describe('rpc.collectors', () => {
	it('describes each installed collector as the exporter sees it', () => {
		with_sys({ wifi: { '.type': 'collector', stations: '0' } }, {}, (sys) => {
			assert.match({
				name: 'wifi', id: 'wifi', title: 'wifi', help: 'The wifi test collector.',
				enabled: true,
				package: `${PACKAGE}-wifi`, base: false,
				options: [ { name: 'stations', type: 'bool', default: true, help: 'The stations option.', datatype: null, value: false, set: true, error: null } ],
				needs: [ 'ubus' ], configs: [], commands: [],
				jail: { paths: [], owned: [], commands: {}, mounts: [], problems: [], missing: [] },
				error: null,
			}, entry(sys, 'wifi'));
		});
	});

	it('lists every installed collector, in order, with what the loader skipped', () => {
		with_sys({}, { skipped: [ 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ] }, (sys) => {
			let res = rpc.collectors(sys);

			assert.match([ 'loadavg', 'wifi', 'textfile', 'wireguard', 'nft-counters', 'sampler' ], map(res.collectors, (c) => c.name));
			assert.match([ 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ], res.skipped);
		});
	});

	it('says which package installed a collector: the base one, its own, or none', () => {
		with_sys({}, {}, (sys) => {
			assert.match([ PACKAGE, true ], [ entry(sys, 'loadavg').package, entry(sys, 'loadavg').base ]);
			assert.match([ `${PACKAGE}-textfile`, false ], [ entry(sys, 'textfile').package, entry(sys, 'textfile').base ]);
			assert.match([ null, null ], [ entry(sys, 'sampler').package, entry(sys, 'sampler').base ]);
		});
	});

	it('gives unset options their defaults, and set ones the typed value', () => {
		with_sys({ sampler: { '.type': 'collector', retries: '7' } }, {}, (sys) => {
			assert.match([
				{ name: 'retries', value: 7, set: true },
				{ name: 'verbose', value: false, set: false },
				{ name: 'label', value: 'x', set: false },
			], map(entry(sys, 'sampler').options, (o) => ({ name: o.name, value: o.value, set: o.set })));
		});
	});

	it('takes the enabled switch from the config', () => {
		with_sys({ loadavg: { '.type': 'collector', enabled: '0' }, wifi: { '.type': 'collector', enabled: 'yes' } }, {}, (sys) => {
			assert.match([ false, true, true ], [ entry(sys, 'loadavg').enabled, entry(sys, 'wifi').enabled, entry(sys, 'textfile').enabled ]);
		});
	});

	it('reports an invalid value as it stands, with the exporter\'s reason', () => {
		with_sys({ sampler: { '.type': 'collector', retries: 'many' } }, {}, (sys) => {
			let e = entry(sys, 'sampler');

			assert.match({ value: 'many', set: true, error: 'expected an integer, got "many"' },
				{ value: e.options[0].value, set: e.options[0].set, error: e.options[0].error });
			assert.match('CONFIG_INVALID (retries: expected an integer, got "many")', e.error);
		});
	});

	it('ignores a section of another type under the collector\'s name, as the exporter does', () => {
		with_sys({ wifi: { '.type': 'interface', stations: 'maybe' } }, {}, (sys) => {
			assert.match([ true, false, null ], [ entry(sys, 'wifi').options[0].value, entry(sys, 'wifi').options[0].set, entry(sys, 'wifi').error ]);
		});
	});

	it('gives the configs, commands and what the jail mounts', () => {
		with_sys({ textfile: { '.type': 'collector', directory: '/srv/prom' } }, { files: [ '/usr/sbin/nft' ] }, (sys) => {
			assert.match([ [ 'network' ], [ '/etc/config/network' ] ], [ entry(sys, 'wireguard').configs, entry(sys, 'wireguard').jail.mounts ]);
			assert.match({ paths: [], owned: [], commands: { nft: '/usr/sbin/nft' }, mounts: [ '/bin/sh', '/usr/sbin/nft' ], problems: [], missing: [] },
				entry(sys, 'nft-counters').jail);
			assert.match([ 'nft' ], entry(sys, 'nft-counters').commands);
			assert.match({ paths: [ '/srv/prom' ], missing: [ '/srv/prom' ] },
				{ paths: entry(sys, 'textfile').jail.paths, missing: entry(sys, 'textfile').jail.missing });
		});
	});

	it('names a command that is missing among the jail\'s problems', () => {
		with_sys({}, {}, (sys) => {
			assert.match({ nft: null }, entry(sys, 'nft-counters').jail.commands);
			assert.match([ `command nft is not on ${jail.PATH}` ], entry(sys, 'nft-counters').jail.problems);
		});
	});

	it('takes the title of a collector that declares one', () => {
		let titled = collector('dawn', { needs: [], title: 'DAWN' });

		with_sys({}, { collectors: [ titled ] }, (sys) => {
			assert.match('DAWN', entry(sys, 'dawn').title);
		});
	});
});

describe('rpc.validate', () => {
	function validate(args, collectors) {
		let out;

		with_sys({}, { collectors: collectors ?? ALL }, (sys) => {
			out = rpc.validate(sys, args);
		});

		return out;
	}

	it('passes valid values for the main section and the collectors', () => {
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate({
			main: { enabled: '1', listen_interface: '*', listen_port: '9102', http_keepalive: '0', cert: '/etc/x.crt', key: '/etc/x.key', omit_zero_values: 'yes' },
			collectors: { wifi: { enabled: '0', stations: 'off' }, sampler: { retries: '-2', label: 'y' } },
		}));
	});

	it('says what the exporter would refuse of the main section, field by field', () => {
		assert.match({ ok: false, errors: { main: {
			listen_port: 'expected an integer from 1 to 65535, got 0',
			http_keepalive: 'expected an integer of 0 or more, got -1',
			omit_zero_values: 'expected a boolean, got "maybe"',
			enabled: 'expected a boolean, got "2"',
		}, collectors: {} } }, validate({
			main: { listen_port: '0', http_keepalive: '-1', omit_zero_values: 'maybe', enabled: '2', listen_interface: 'lan' },
		}));
	});

	it('says what the exporter would refuse of a collector\'s options and its enabled switch', () => {
		assert.match({ ok: false, errors: { main: {}, collectors: {
			wifi: { enabled: 'expected a boolean, got "maybe"', stations: 'expected a boolean, got "x"' },
			sampler: { retries: 'expected an integer, got "1.5"', label: 'expected a single value, got [ "a", "b" ]' },
		} } }, validate({
			collectors: { wifi: { enabled: 'maybe', stations: 'x' }, sampler: { retries: '1.5', label: [ 'a', 'b' ], verbose: '1' } },
		}));
	});

	it('takes an empty or missing value as unset, which is the default', () => {
		assert.match(true, validate({ main: { listen_port: '', listen_interface: null }, collectors: { sampler: { retries: '' } } }).ok);
	});

	it('ignores options nobody declared and collectors that are not installed, as the exporter does', () => {
		assert.match(true, validate({ main: { listen_addr: 'x' }, collectors: { wifi: { nope: 'x' }, ghost: { enabled: 'maybe' } } }).ok);
	});

	it('refuses malformed arguments', () => {
		assert.match([
			{ error: rpc.ARGS_INVALID, message: 'main and collectors must be objects' },
			{ error: rpc.ARGS_INVALID, message: 'main and collectors must be objects' },
			{ error: rpc.ARGS_INVALID, message: 'collectors.wifi must be an object' },
		], [
			validate({ main: [ 'x' ] }),
			validate({ collectors: 'wifi' }),
			validate({ collectors: { wifi: '0' } }),
		]);
	});

	it('passes nothing at all', () => {
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate(null));
	});

	prop('refuses a boolean option exactly when the exporter cannot read it',
		gen.string({ charset: 'abdefilnorstuy01', min_len: 1, max_len: 8 }), (s) => {
			let res = validate({ collectors: { wifi: { stations: s } } });
			assert.match(!config.convert('stations', s, { default: true }).ok, res.errors.collectors.wifi?.stations != null);
		});

	prop('refuses a port exactly when the init script would',
		gen.string({ charset: '-0123456789x', min_len: 1, max_len: 6 }), (s) => {
			let n = match(s, /^-?[0-9]+$/) ? int(s) : null;
			let res = validate({ main: { listen_port: s } });
			assert.match(n == null || n < 1 || n > 65535, res.errors.main.listen_port != null);
		});
});

describe('rpc.service', () => {
	const RUNNING = { [NAME]: { instances: { instance1: { running: true,
		command: [ '/usr/sbin/uhttpd', '-f', '-p', '192.168.1.1:9100', '-p', '[fd00::1]:9100' ] } } } };

	function service(own, ubus, links) {
		let out;

		with_sys(own, { ubus, links }, (sys) => {
			out = rpc.service(sys);
		});

		return out;
	}

	it('says a running instance runs, and where it listens', () => {
		assert.match({
			service: { enabled: true, boot: true, running: true, error: null },
			listen: [ 'http://192.168.1.1:9100/metrics', 'http://[fd00::1]:9100/metrics' ],
		}, service({}, { data: { 'service:list': RUNNING } }, [ `${rpc.RC_DIR}/S60${NAME}` ]));
	});

	it('says a service without instances is not running, and listens nowhere', () => {
		assert.match({
			service: { enabled: false, boot: false, running: false, error: null },
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

	it('says when procd cannot be asked, and when the main section is invalid', () => {
		assert.match({
			service: { enabled: null, boot: false, running: null, error: 'UBUS_CALL_FAILED (service list: Not found)' },
			listen: [],
		}, service({ main: { '.type': NAME, enabled: 'maybe' } }, { errors: { 'service:list': 'Not found' } }));
	});
});

describe('rpc.scrape_report and rpc.status', () => {
	it('runs each enabled collector once, and says how it did', () => {
		with_sys({ textfile: { '.type': 'collector', enabled: '0' } }, { collectors: [ LOADAVG, FAILING, TEXTFILE ] }, (sys) => {
			assert.match([
				{ name: 'loadavg', id: 'loadavg', title: 'loadavg', enabled: true, success: true, duration: 0.005, error: null, mounts: [] },
				{ name: 'openwrt', id: 'openwrt', title: 'openwrt', enabled: true, success: false, duration: 0.005,
					error: 'UBUS_CALL_FAILED (system board: Not found)', mounts: [] },
				{ name: 'textfile', id: 'textfile', title: 'textfile', enabled: false, success: null, duration: null, error: null, mounts: [] },
			], rpc.scrape_report(sys));
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

			assert.match([ 'collectors', 'listen', 'service' ], sort(keys(res)));
			assert.match([ 'loadavg' ], map(res.collectors, (c) => c.name));
		});
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

		assert.match([ 'collectors', 'interfaces', 'status', 'validate' ], sort(keys(m)));
		assert.match({ collectors: [], skipped: [] }, m.collectors.call({ args: {} }));
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, m.validate.call({ args: { main: { listen_port: '80' } } }));
		assert.match(2, made);
		m.status.call({ args: {}, defer: () => null });
		assert.match([ `${rpc.STATUS_HELPER} 2>/dev/null` ], commands);
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

		assert.match([ {}, { main: {}, collectors: {} }, {}, {} ], [ m.collectors.args, m.validate.args, m.status.args, m.interfaces.args ]);
	});

	it('names the object and the helper after the exporter\'s package', () => {
		assert.match([ NAME, `/usr/libexec/${NAME}/rpc-status.uc` ], [ rpc.OBJECT, rpc.STATUS_HELPER ]);
	});
});
