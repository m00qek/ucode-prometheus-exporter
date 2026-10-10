'use strict';

// What the service's ubus object gives the collectors of root's sources:
// the fields they read, and no secret of what root reads.

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import * as sources from 'prometheus.exporter.rpc.sources';
import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as rpc from 'prometheus.exporter.rpc';

const STATUS = fixtures.ubus('caju-ap', 'network.wireless', 'status');

// A ubus capability answering `replies` by 'object:method', a function of
// the arguments where it is one, failing with `failures`' status.
function ubus(replies, failures) {
	let calls = [];

	return {
		calls,
		call: function(object, method, args) {
			let key = `${object}:${method}`;

			push(calls, [ key, args ]);
			if (failures?.[key])
				return Result.err(errors.UBUS_CALL_FAILED, `${object} ${method}: ${failures[key]}`, { status: failures[key] });

			let r = replies[key];
			return Result.ok(type(r) == 'function' ? r(args) : r);
		},
	};
}

// A uci cursor of the config `network`, as sections by name.
function cursor(network) {
	return {
		load: (c) => c == 'network',
		foreach: function(config, stype, cb) {
			if (config == 'network')
				for (let name, s in network)
					cb({ '.name': name, ...s });
		},
	};
}

describe('rpc.sources.wireless', () => {
	it('keeps of netifd\'s status what wifi and hostapd_stations read, and no key', () => {
		let got = sources.wireless(STATUS);

		assert.match({
			up: true, disabled: false,
			config: { channel: '11', country: 'BR', htmode: 'HE20' },
			interfaces: [ { ifname: 'phy0-ap0', config: { ssid: 'iot', encryption: 'psk2' } } ],
		}, got.radios.radio_2G);
		assert.match(false, index(sprintf('%J', got), 'REDACTED') >= 0);
	});

	it('is what the AP\'s capture of the object\'s reply holds', () => {
		assert.match(fixtures.ubus('caju-ap', 'prometheus-exporter', 'wireless'), sources.wireless(STATUS));
	});

	prop('lets no secret of a network\'s or radio\'s config through, whatever its option is named',
		gen.tuple(gen.elements('key', 'sae_password', 'auth_secret', 'password', 'priv_key_pwd', 'wpa_psk_file', 'key1'),
			gen.alphanumeric({ min_len: 8, max_len: 24 })), (t) => {
			let status = { radio0: {
				up: true, [t[0]]: `x${t[1]}`,
				config: { channel: '1', [t[0]]: `x${t[1]}` },
				interfaces: [ { ifname: 'wlan0', [t[0]]: `x${t[1]}`, config: { ssid: 'lab', [t[0]]: `x${t[1]}`, network: [ `x${t[1]}` ] } } ],
			} };

			assert.match(false, index(sprintf('%J', sources.wireless(status)), t[1]) >= 0);
		});

	it('leaves out what is not a radio or an interface, and an interface without its name', () => {
		assert.match({ radios: { r: { config: {}, interfaces: [] } } },
			sources.wireless({ r: { interfaces: [ { config: { ssid: 'x' } }, null ] }, s: 'x', t: null }));
		assert.match({ radios: {} }, sources.wireless(null));
	});
});

describe('rpc.sources.wireguard_peers', () => {
	it('gives each peer\'s description by interface and public key, and is what the router\'s capture holds', () => {
		let values = fixtures.ubus('caju-router', 'uci', 'get').values;

		assert.match(fixtures.ubus('caju-router', 'prometheus-exporter', 'wireguard_peers'), sources.wireguard_peers(cursor(values)));
	});

	prop('lets no other option of a peer section, nor any interface section, through', gen.alphanumeric({ min_len: 8, max_len: 24 }), (secret) => {
		let network = {
			wg0: { '.type': 'interface', proto: 'wireguard', private_key: `k${secret}` },
			peer: { '.type': 'wireguard_wg0', public_key: 'PUB=', description: 'hub', preshared_key: `p${secret}`, endpoint_host: `h${secret}` },
			nameless: { '.type': 'wireguard_wg0', public_key: 'OTHER=', preshared_key: `p${secret}` },
		};
		let got = sources.wireguard_peers(cursor(network));

		assert.match({ interfaces: { wg0: { 'PUB=': 'hub' } } }, got);
		assert.match(false, index(sprintf('%J', got), secret) >= 0);
	});
});

describe('rpc.sources.time_daemons', () => {
	it('says whether each daemon runs its program, and nothing of procd\'s command lines', () => {
		let lists = {
			sysntpd: fixtures.ubus('caju-ap', 'service.list', 'sysntpd'),
			chronyd: fixtures.ubus('seriguela-router', 'service.list', 'chronyd'),
		};

		assert.match({ running: { sysntpd: true, chronyd: true } }, sources.time_daemons(lists));
		assert.match({ running: { sysntpd: false, chronyd: false } }, sources.time_daemons({}));
	});

	it('is what each device\'s capture of the object\'s reply holds', () => {
		for (let set in [ 'caju-ap', 'seriguela-router' ]) {
			let lists = {};

			for (let name in keys(sources.TIME_DAEMONS))
				try {
					lists[name] = fixtures.ubus(set, 'service.list', name);
				} catch (e) {
					lists[name] = {};
				}
			assert.match(fixtures.ubus(set, 'prometheus-exporter', 'time_daemons'), sources.time_daemons(lists), set);
		}
	});

	it('takes an instance for the daemon only when it runs the daemon\'s program', () => {
		let list = (command, running) => ({ sysntpd: { instances: { i: { running, command } } } });

		assert.match([ true, false, false, false ], map([
			list([ '/usr/sbin/ntpd', '-n' ], true),
			list([ '/usr/sbin/ntpd', '-n' ], false),
			list([ '/usr/sbin/ntpd-hotplug' ], true),
			list(null, true),
		], (l) => sources.time_daemons({ sysntpd: l }).running.sysntpd));
	});
});

describe('rpc.sources, asked as root', () => {
	// netifd is asked by ubus's command line, apart from rpcd, which a hung
	// netifd would otherwise hold: what it prints, then its exit status.
	it('wireless_reply makes wireless() of what ubus printed, and says no radios where netifd has no network.wireless', () => {
		assert.match(sources.wireless(STATUS), sources.wireless_reply(sprintf('%J\n0\n', STATUS)));
		assert.match({ radios: {} }, sources.wireless_reply('{}\n0\n'));
		assert.match({ radios: {} }, sources.wireless_reply('Command failed: Not found\n4\n'));
		assert.match({ error: 'UBUS_CALL_FAILED', message: 'network.wireless status: Request timed out' }, sources.wireless_reply('7\n'));
		assert.match({ error: 'UBUS_CALL_FAILED', message: 'network.wireless status: Failed to connect to ubus' },
			sources.wireless_reply('Failed to connect to ubus\n255\n'));
		assert.match({ error: 'UBUS_CALL_FAILED', message: 'network.wireless status: no answer' }, sources.wireless_reply(''));
		assert.match({ error: 'UBUS_CALL_FAILED', message: 'network.wireless status: exit status 127' }, sources.wireless_reply('127\n'));
		assert.match({ error: 'SOURCE_INVALID', message: 'network.wireless status: not JSON' }, sources.wireless_reply('{"radio0":\n0\n'));
	});

	it('wireless runs ubus\'s command line for netifd, with a timeout, and replies once it is done', () => {
		let watched = null, replies = [], commands = [];
		let io = {
			popen: function(cmd) { push(commands, cmd); return { read: () => sprintf('%J\n0\n', STATUS), close: () => 0 }; },
			watch: function(p, cb) { watched = cb; },
		};
		let req = { args: {}, reply: (r) => push(replies, r), defer: () => 'deferred' };

		assert.match('deferred', rpc.methods(() => die('no sys'), io).wireless.call(req));
		assert.match([ sources.WIRELESS_COMMAND ], commands);
		assert.match(0, index(sources.WIRELESS_COMMAND, `ubus -S -t ${sources.WIRELESS_SECONDS} call network.wireless status`));
		assert.match([], replies);
		watched();
		assert.match([ sources.wireless(STATUS) ], replies);
	});

	it('time_daemons_of asks procd of each daemon alone', () => {
		let u = ubus({ 'service:list': (args) => (args.name == 'sysntpd') ? fixtures.ubus('caju-ap', 'service.list', 'sysntpd') : {} });

		assert.match({ running: { sysntpd: true, chronyd: false } }, sources.time_daemons_of(u));
		assert.match([ [ 'service:list', { name: 'sysntpd' } ], [ 'service:list', { name: 'chronyd' } ] ], u.calls);
		assert.match('UBUS_CALL_FAILED', sources.time_daemons_of(ubus({}, { 'service:list': 'Request timed out' })).error);
	});

	it('are methods of the ubus object, which take no arguments', () => {
		let m = rpc.methods(() => null, null);

		for (let name in [ 'wireless', 'wireguard_peers', 'time_daemons' ])
			assert.match({}, m[name]?.args, name);
	});
});
