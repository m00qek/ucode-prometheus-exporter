'use strict';

// What the service's ubus object gives the collectors of root's sources:
// the fields they read, and no secret of what root reads.

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import * as sources from 'prometheus.exporter.rpc.sources';
import { NO_UCI_DELTAS } from 'prometheus.exporter.state';

// netifd's status of the AP's radios, with each network's interface.
const STATUS = fixtures.ubus('caju-ap', 'network.wireless', 'status');

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

// A cursor of these configs, each { section: options }, in their order.
function configs(all) {
	return {
		load: (c) => all[c] != null,
		foreach: function(config, stype, cb) {
			for (let name, s in all[config] ?? {})
				if (stype == null || s['.type'] == stype)
					cb({ '.name': name, ...s });
		},
	};
}

// sysfs of these phys: { name: [ index, device, macaddr ] }.
function sysfs(phys) {
	return {
		lsdir: (p) => (p == sources.PHYS) ? keys(phys) : null,
		readfile: function(p) {
			let m = match(p, /^\/sys\/class\/ieee80211\/([^\/]+)\/(index|macaddr)$/);
			let ph = m ? phys[m[1]] : null;

			return ph ? `${(m[2] == 'index') ? ph[0] : ph[2]}\n` : null;
		},
		realpath: function(p) {
			let m = match(p, /^\/sys\/class\/ieee80211\/([^\/]+)\/device$/);

			return m ? phys[m[1]]?.[1] : null;
		},
	};
}

const DEV = '/sys/devices/platform/soc/18000000.wifi';
const PHYS = { phy0: [ 0, DEV, '02:00:00:00:a0:00' ], phy1: [ 1, DEV, '02:00:00:00:a0:10' ] };

function radio(more) {
	return { '.type': 'wifi-device', type: 'mac80211', path: 'platform/soc/18000000.wifi', channel: '36', ...(more ?? {}) };
}

function vif(device, more) {
	return { '.type': 'wifi-iface', device, mode: 'ap', network: 'lan', ssid: 'lab', encryption: 'sae', ...(more ?? {}) };
}

// The interface of each network of each radio, null where it has none.
function names(wireless, network, phys) {
	let got = sources.wireless(configs({ wireless, network }), sysfs(phys ?? PHYS));
	let out = {};

	for (let r, v in got.radios)
		out[r] = map(v.interfaces, (i) => i.ifname);

	return out;
}

describe('rpc.sources.wireless', () => {
	it('is what the AP\'s capture of the object\'s reply holds: its config without keys, the interfaces netifd named', () => {
		let got = sources.wireless(fixtures.cursor('caju-ap'), fixtures.sysfs('caju-ap'));

		assert.match(fixtures.ubus('caju-ap', 'prometheus-exporter', 'wireless'), got);
		for (let r, v in STATUS)
			assert.match(map(v.interfaces, (i) => i.ifname), map(got.radios[r].interfaces, (i) => i.ifname), r);
		assert.match(false, index(sprintf('%J', got), 'REDACTED') >= 0);
	});

	it('keeps of the config what wifi and hostapd_stations read', () => {
		let got = sources.wireless(configs({ wireless: { radio0: radio({ disabled: '1', country: 'BR', htmode: 'HE80', txpower: '20' }),
			n: vif('radio0', { mesh_id: 'm', key: 'secret' }) } }), sysfs(PHYS));

		assert.match({ radios: { radio0: { disabled: true, config: { channel: '36', country: 'BR', htmode: 'HE80' },
			interfaces: [ { config: { ssid: 'lab', mesh_id: 'm', encryption: 'sae' } } ] } } }, got);
	});

	prop('lets no secret of a network\'s or radio\'s config through, whatever its option is named',
		gen.tuple(gen.elements('key', 'sae_password', 'auth_secret', 'password', 'priv_key_pwd', 'wpa_psk_file', 'key1'),
			gen.alphanumeric({ min_len: 8, max_len: 24 })), (t) => {
			let wireless = {
				radio0: radio({ [t[0]]: `x${t[1]}` }),
				n: vif('radio0', { [t[0]]: `x${t[1]}`, network: [ `x${t[1]}` ] }),
			};

			assert.match(false, index(sprintf('%J', sources.wireless(configs({ wireless }), sysfs(PHYS))), t[1]) >= 0);
		});

	// Its index counts the networks of its mode before it, an ifname of their
	// own and OWE's transition network as one more included, as mac80211.sh's.
	it('names a network as netifd does: its ifname, else the phy\'s prefix, its mode and its index among the radio\'s of that mode', () => {
		assert.match({ radio0: [ 'phy0-ap0', 'phy0-ap1', 'phy0-sta0', 'phy0-mesh0', 'guest0', 'phy0-ap3', 'phy0-ap4', 'phy0-ap6' ] }, names({
			radio0: radio(),
			a: vif('radio0'), b: vif('radio0'), c: vif('radio0', { mode: 'sta' }), d: vif('radio0', { mode: 'mesh' }),
			e: vif('radio0', { ifname: 'guest0' }), f: vif('radio0'), g: vif('radio0', { mode: null, encryption: 'owe', owe_transition: '1' }),
			h: vif('radio0'),
		}));
	});

	it('finds a radio\'s phy by its path, the Nth of the device\'s with +N, by MAC address, or by name', () => {
		let wireless = (r) => ({ radio0: r, a: vif('radio0') });

		assert.match([ 'phy0-ap0' ], names(wireless(radio())).radio0);
		assert.match([ 'phy1-ap0' ], names(wireless(radio({ path: 'platform/soc/18000000.wifi+1' }))).radio0);
		assert.match([ 'phy1-ap0' ], names(wireless(radio({ path: null, macaddr: '02:00:00:00:A0:10' }))).radio0);
		assert.match([ 'phy1-ap0' ], names(wireless(radio({ path: null, phy: 'phy1' }))).radio0);
		assert.match([ 'phy1-ap0' ], names(wireless(radio({ path: 'pci0000:00/0000:00:01.0', phy: 'phy1' }))).radio0);
		assert.match([ null ], names(wireless(radio({ path: 'pci0000:00/0000:00:01.0' }))).radio0);
		// The device's phys in the order of their indexes, not of their names.
		assert.match([ 'phy7-ap0' ], names(wireless(radio({ path: 'platform/soc/18000000.wifi+1' })), null,
			{ phy9: [ 0, DEV ], phy7: [ 1, DEV ] }).radio0);
	});

	it('takes the radio\'s ifname_prefix, and for a radio of a phy of several, its index', () => {
		assert.match({ radio0: [ 'wl0-ap0' ], radio1: [ 'phy0.1-ap0' ] }, names({
			radio0: radio({ ifname_prefix: 'wl0-' }), radio1: radio({ radio: '1' }),
			a: vif('radio0'), b: vif('radio1'),
		}));
	});

	// netifd sets up no network of a disabled radio, nor a disabled network,
	// nor one whose logical interfaces are all disabled; an MLO network it
	// names otherwise.
	it('names no network netifd does not set up, and counts none of them', () => {
		assert.match({ radio0: [ null ], radio1: [ 'phy1-ap0', null, 'phy1-ap1', 'phy1-ap2', null, null ] }, names({
			radio0: radio({ disabled: '1' }), radio1: radio({ path: 'platform/soc/18000000.wifi+1' }),
			a: vif('radio0'),
			b: vif('radio1'),
			c: vif('radio1', { network: 'guest' }),
			off: vif('radio1', { disabled: '1' }),
			d: vif('radio1', { network: 'nowhere' }),
			e: vif('radio1', { network: [ 'guest', 'lan' ] }),
			f: vif('radio1', { network: 'iot' }),
			g: vif('radio1', { network: 'lan', mlo: '1' }),
		}, {
			lan: { '.type': 'interface', proto: 'static' },
			guest: { '.type': 'interface', proto: 'static', auto: '0' },
			iot: { '.type': 'interface', proto: 'static', disabled: '1' },
		}));
	});

	it('has no radios without a wireless config, and names nothing without a phy', () => {
		assert.match({ radios: {} }, sources.wireless(configs({}), sysfs(PHYS)));
		assert.match({ radio0: [ null ] }, names({ radio0: radio(), a: vif('radio0') }, null, {}));
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

// A ubus connection whose calls procd answers when the test says, as ubus's
// defer() does: each call is kept with the callback it is answered by.
function procd(fails) {
	let calls = [];

	return {
		calls,
		defer: function(object, method, args, cb) {
			if (fails)
				return null;
			push(calls, { object, method, args, cb });
			return 'pending';
		},
		error: () => 'Connection failed',
	};
}

function request() {
	let replies = [];

	return { replies, reply: (r) => push(replies, r), defer: () => 'deferred' };
}

// /proc, as rpcd reads it: each process's command line, by pid.
function proc_fs(cmdlines) {
	return {
		lsdir: (path) => (path == '/proc') ? [ ...keys(cmdlines), 'self', 'net' ] : null,
		readfile: (path) => cmdlines[split(path, '/')[2]],
	};
}

describe('rpc.sources.ask_time_daemons', () => {
	it('asks procd of each daemon at once, without waiting, and replies once both answered', () => {
		let conn = procd(), req = request(), timeouts = [];
		let connect = function(path, t) {
			push(timeouts, t);
			return conn;
		};

		assert.match('deferred', sources.ask_time_daemons({ conn: null }, connect, req));
		assert.match([ sources.PROCD_SECONDS ], timeouts);
		assert.match([ [ 'service', 'list', { name: 'sysntpd' } ], [ 'service', 'list', { name: 'chronyd' } ] ],
			map(conn.calls, (c) => [ c.object, c.method, c.args ]));
		conn.calls[0].cb(0, fixtures.ubus('caju-ap', 'service.list', 'sysntpd'));
		assert.match([], req.replies);
		conn.calls[1].cb(0, {});
		assert.match([ { running: { sysntpd: true, chronyd: false } } ], req.replies);
	});

	it('keeps its connection for the next call', () => {
		let made = 0, conn = procd(), state = { conn: null };
		let connect = function() {
			made++;
			return conn;
		};

		sources.ask_time_daemons(state, connect, request());
		sources.ask_time_daemons(state, connect, request());
		assert.match([ 1, 4 ], [ made, length(conn.calls) ]);
	});

	it('replies UBUS_CALL_FAILED when procd does not answer in time, as libubus says it', () => {
		let conn = procd(), req = request();

		sources.ask_time_daemons({ conn: null }, () => conn, req);
		conn.calls[0].cb(7, null);
		conn.calls[1].cb(0, {});
		assert.match([ { error: 'UBUS_CALL_FAILED', message: 'service list sysntpd: Request timed out' } ], req.replies);
	});

	it('replies UBUS_CALL_FAILED when a call cannot be made, and connects again for the next', () => {
		let made = 0, state = { conn: null }, req = request();
		let connect = function() {
			made++;
			return procd(made == 1);
		};

		sources.ask_time_daemons(state, connect, req);
		assert.match([ { error: 'UBUS_CALL_FAILED', message: 'service list sysntpd: Connection failed' } ], req.replies);
		sources.ask_time_daemons(state, connect, request());
		assert.match([ 2, 2 ], [ made, length(state.conn.calls) ]);
	});

	it('answers UBUS_CONNECT_FAILED without deferring when ubus is not there', () => {
		let req = request();

		assert.match({ error: 'UBUS_CONNECT_FAILED', message: 'cannot connect to ubus' },
			sources.ask_time_daemons({ conn: null }, () => null, req));
		assert.match([], req.replies);
	});

	// 25.12.0's rpcd gives its ucode plugins requests without defer(), and
	// waiting for procd would hold rpcd: /proc says it at once.
	it('answers from /proc, asking nothing of ubus, where the request has no defer()', () => {
		let fs = proc_fs({ '1': '/sbin/procd\0', '812': '/usr/sbin/ntpd\0-n\0-N\0', '813': '/usr/sbin/ntpd-hotplug\0', '900': '' });

		assert.match({ running: { sysntpd: true, chronyd: false } },
			sources.ask_time_daemons({ conn: null }, () => die('connected'), { reply: () => die('replied') }, fs));
	});
});

describe('rpc.sources.running_in_proc', () => {
	it('says a daemon runs while a process runs its program, as procd starts it', () => {
		let running = (cmdlines) => sources.running_in_proc(proc_fs(cmdlines)).running;

		assert.match([
			{ sysntpd: false, chronyd: false },
			{ sysntpd: true, chronyd: true },
			{ sysntpd: false, chronyd: false },
		], [
			running({ '1': '/sbin/procd\0' }),
			running({ '7': '/usr/sbin/ntpd\0-n\0', '8': '/usr/sbin/chronyd\0-n\0' }),
			running({ '7': '/usr/sbin/ntpd-hotplug\0', '8': 'chronyd\0', '9': '' }),
		]);
	});
});

describe('rpc.sources.methods', () => {
	it('are wireless, wireguard_peers and time_daemons, which take no arguments', () => {
		let m = sources.methods({ cursor: () => die('no cursor'), fs: null, connect: () => null });

		assert.match([ 'time_daemons', 'wireguard_peers', 'wireless' ], sort(keys(m)));
		for (let name, method in m)
			assert.match({}, method.args, name);
	});

	it('read the configs with a cursor of the committed changes alone, made for each call', () => {
		let opened = [];
		let open = function(dir, deltas) {
			push(opened, [ dir, deltas ]);
			return configs({});
		};
		let m = sources.methods(sources.system(open, { lsdir: () => [], readfile: () => null, realpath: () => null }, () => null));

		assert.match({ radios: {} }, m.wireless.call({}));
		assert.match({ interfaces: {} }, m.wireguard_peers.call({}));
		assert.match([ [ null, NO_UCI_DELTAS ], [ null, NO_UCI_DELTAS ] ], opened);
	});

	// rpcd answers a scrape's wireless twice (wifi's, hostapd_stations'),
	// and the configs and the phys rarely change: reading them again costs
	// an access point's scrape some 2 ms a call.
	it('answer wireless again, without reading the configs, while their files and the phys are as they were', () => {
		let opened = 0;
		let files = { '/etc/config/wireless': { inode: 7, size: 900, mtime: 1, ctime: 1 }, '/etc/config/network': { inode: 8, size: 1700, mtime: 1, ctime: 1 } };
		let phys = { ...PHYS };
		let wireless = { radio0: radio(), wifinet0: vif('radio0') };
		let fs = { ...sysfs(phys), stat: (p) => files[p] };
		let open = function() {
			opened++;
			return configs({ wireless });
		};
		let m = sources.methods(sources.system(open, fs, () => null));
		let first = m.wireless.call({});

		assert.match([ 'phy0-ap0' ], names(wireless).radio0);
		assert.match([ first, 1 ], [ m.wireless.call({}), opened ]);

		files['/etc/config/wireless'] = { ...files['/etc/config/wireless'], inode: 9 };
		m.wireless.call({});
		files['/etc/config/network'] = { ...files['/etc/config/network'], mtime: 2 };
		m.wireless.call({});
		delete files['/etc/config/network'];
		m.wireless.call({});
		assert.match(4, opened);

		phys.phy0 = [ 0, '/sys/devices/platform/soc/18000001.wifi', '02:00:00:00:a0:00' ];
		assert.match([ 'phy1-ap0' ], map(m.wireless.call({}).radios.radio0.interfaces, (i) => i.ifname));
		assert.match([ 5, 5 ], [ opened, (m.wireless.call({}), opened) ]);
	});

	it('read the configs at each call without stat', () => {
		let opened = 0;
		let m = sources.methods(sources.system(() => { opened++; return configs({}); }, { ...sysfs(PHYS), stat: null }, () => null));

		m.wireless.call({});
		m.wireless.call({});
		assert.match(2, opened);
	});
});
