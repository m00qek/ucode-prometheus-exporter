/**
 * What the ubus object gives collectors of root's sources: the fields they read, never a secret.
 *
 * @module prometheus_exporter_rpc_sources
 */

'use strict';

import * as errors from 'prometheus.exporter.errors';
import { NO_UCI_DELTAS } from 'prometheus.exporter.state';

/**
 * What the sources' methods take of the system, in rpcd's own process.
 *
 * @typedef {{
 *   cursor: function(): UciCursor,
 *   fs: { lsdir: function(string): ?string[], readfile: function(string): ?string, realpath: function(string): ?string, stat: ?function(string): ?Object },
 *   connect: function(?string, int): ?UbusConnection
 * }} SourcesSys
 */

/**
 * The fields of a radio's config that wireless() keeps.
 *
 * @type {string[]}
 */
export const RADIO_CONFIG = [ 'channel', 'country', 'htmode' ];

/**
 * The fields of a wifi-iface's config that wireless() keeps: no key, password or secret.
 *
 * @type {string[]}
 */
export const IFACE_CONFIG = [ 'ssid', 'mesh_id', 'encryption' ];

/**
 * Where the kernel lists the Wi-Fi phys, each with its device, index and MAC address.
 *
 * @type {string}
 */
export const PHYS = '/sys/class/ieee80211';

/**
 * The mode of a wifi-iface that has none, as wifi-scripts take it.
 *
 * @type {string}
 */
export const DEFAULT_MODE = 'ap';

/**
 * The seconds the method `time_daemons` waits for procd.
 *
 * @type {int}
 */
export const PROCD_SECONDS = 3;

/**
 * libubus's text of each status, which a call fails with.
 *
 * @type {string[]}
 */
export const UBUS_STATUS = [
	'Success', 'Invalid command', 'Invalid argument', 'Method not found', 'Not found', 'No response',
	'Permission denied', 'Request timed out', 'Operation not supported', 'Unknown error', 'Connection failed',
];

/**
 * The procd services time_daemons() says of, and the program each runs.
 *
 * @type {Object<string, string>}
 */
export const TIME_DAEMONS = { sysntpd: '/usr/sbin/ntpd', chronyd: '/usr/sbin/chronyd' };

const SCALAR = { string: true, int: true, double: true, bool: true };

const TRUE = { '1': true, on: true, true: true, yes: true, enabled: true };

function pick(obj, fields) {
	let out = {};

	for (let f in fields)
		if (SCALAR[type(obj?.[f])])
			out[f] = obj[f];

	return out;
}

function bool(v) {
	return TRUE[v] === true;
}

function list(v) {
	return (type(v) == 'array') ? v : ((type(v) == 'string') ? split(trim(v), /\s+/) : []);
}

/**
 * The Wi-Fi phys of sysfs, each with its device's path and its index, in the order of their indexes.
 *
 * @param {Object} fs what reads sysfs: lsdir, readfile and realpath.
 * @returns {{ name: string, device: ?string, index: int }[]} the phys.
 */
export function phys(fs) {
	return sort(map(fs.lsdir(PHYS) ?? [], (name) => ({
		name,
		device: fs.realpath(`${PHYS}/${name}/device`),
		index: +trim(fs.readfile(`${PHYS}/${name}/index`) ?? ''),
	})), (a, b) => (a.index - b.index) || ((a.name < b.name) ? -1 : 1));
};

/**
 * The phy of a radio as wifi-scripts find it, by its path (`+N` the Nth of the device's), MAC address or name; null for none.
 *
 * @param {Object} fs what reads sysfs: readfile, for a MAC address.
 * @param {{ name: string, device: ?string, index: int }[]} all the phys, as phys() gives them.
 * @param {Object} radio the radio's wifi-device section.
 * @returns {?string} the phy's name.
 */
export function phy_of(fs, all, radio) {
	if (type(radio.path) == 'string' && radio.path != '') {
		let path = split(radio.path, '+');
		let found = filter(all, (p) => p.device != null && substr(p.device, -length(path[0])) == path[0])[+(path[1] ?? 0)];

		if (found != null)
			return found.name;
	}

	if (type(radio.macaddr) == 'string')
		for (let p in all)
			if (lc(trim(fs.readfile(`${PHYS}/${p.name}/macaddr`) ?? '')) == lc(radio.macaddr))
				return p.name;

	for (let p in all)
		if (p.name == radio.phy)
			return p.name;

	return null;
};

function interfaces_enabled(uci) {
	let enabled = {};

	if (uci.load('network'))
		uci.foreach('network', 'interface', function(s) {
			enabled[s['.name']] = !bool(s.disabled) && s.auto !== '0';
		});

	return enabled;
}

function vif_runs(vif, enabled) {
	let on = null;

	for (let n in list(vif.network))
		if (n in enabled)
			on = on || enabled[n];

	return on !== false;
}

/**
 * Each radio of the wireless config, with the fields the collectors read, and each of its networks' interface as netifd names it.
 *
 * @param {UciCursor} uci a cursor that reads the wireless and network configs.
 * @param {Object} fs what reads sysfs, to find each radio's phy: lsdir, readfile and realpath.
 * @param {?Array} all the phys, as phys() gives them; null to read them where a radio needs one.
 * @returns {{ radios: Object<string, Object> }} by radio: disabled, config and interfaces ({ ifname, config }); no ifname where the network is not set up.
 */
export function wireless(uci, fs, all) {
	let radios = {}, prefixes = {}, vifs = [];

	if (!uci.load('wireless'))
		return { radios };

	uci.foreach('wireless', null, function(s) {
		if (s['.type'] == 'wifi-iface') {
			push(vifs, s);
			return;
		}
		if (s['.type'] != 'wifi-device')
			return;

		let disabled = bool(s.disabled);
		let phy = disabled ? null : phy_of(fs, all ??= phys(fs), s);
		let radio = (s.radio != null && +s.radio >= 0) ? `.${+s.radio}` : '';

		radios[s['.name']] = { disabled, config: pick(s, RADIO_CONFIG), interfaces: [] };
		prefixes[s['.name']] = (phy != null) ? (s.ifname_prefix ?? `${phy}${radio}-`) : null;
	});

	let enabled = length(vifs) ? interfaces_enabled(uci) : {};
	let counted = {};

	for (let vif in vifs) {
		if (bool(vif.disabled))
			continue;

		let mode = vif.mode ?? DEFAULT_MODE;
		let runs = !bool(vif.mlo) && vif_runs(vif, enabled);

		for (let name in list(vif.device)) {
			let r = radios[name];

			if (r == null)
				continue;

			let iface = {};

			if (runs && prefixes[name] != null) {
				let of = counted[name] ??= {};
				let i = of[mode] ?? 0;

				of[mode] = i + ((vif.encryption == 'owe' && bool(vif.owe_transition)) ? 2 : 1);
				iface.ifname = (type(vif.ifname) == 'string') ? vif.ifname : `${prefixes[name]}${mode}${i}`;
			}

			iface.config = pick(vif, IFACE_CONFIG);
			push(r.interfaces, iface);
		}
	}

	return { radios };
};

/**
 * The configs' files that wireless() reads.
 *
 * @type {string[]}
 */
export const WIRELESS_FILES = [ '/etc/config/wireless', '/etc/config/network' ];

function file_key(fs, path) {
	let st = fs.stat(path);

	return st ? `${st.inode}:${st.size}:${st.mtime}:${st.ctime}` : '-';
}

/**
 * wireless() of the committed configs, or the reply `held` keeps while the configs' files and the phys are as they were for it.
 *
 * @param {SourcesSys} sys the system; without fs.stat, nothing is kept.
 * @param {{ key: ?string, reply: ?Object }} held the last reply and what it was of, which it updates.
 * @returns {{ radios: Object<string, Object> }} wireless()'s reply.
 */
export function wireless_held(sys, held) {
	let all = phys(sys.fs);
	let key = (sys.fs?.stat != null) ? sprintf('%s %J', join(' ', map(WIRELESS_FILES, (f) => file_key(sys.fs, f))), all) : null;

	if (key != null && key === held.key)
		return held.reply;

	let reply = wireless(sys.cursor(), sys.fs, all);

	held.key = key;
	held.reply = reply;
	return reply;
};

/**
 * The description of each WireGuard peer of the network config, by interface and public key: nothing else of it.
 *
 * @param {UciCursor} uci a cursor that reads the network config.
 * @returns {{ interfaces: Object<string, Object<string, string>> }} by interface, then public key.
 */
export function wireguard_peers(uci) {
	let interfaces = {};

	uci.load('network');
	uci.foreach('network', null, function(s) {
		let m = match(s['.type'] ?? '', /^wireguard_(.+)$/);

		if (m && type(s.public_key) == 'string' && type(s.description) == 'string') {
			interfaces[m[1]] ??= {};
			interfaces[m[1]][s.public_key] = s.description;
		}
	});

	return { interfaces };
};

/**
 * Whether each of TIME_DAEMONS runs its program, from procd's `service list` of it.
 *
 * @param {Object<string, *>} lists procd's `service list` of each, by name.
 * @returns {{ running: Object<string, boolean> }} whether each runs, by name.
 */
export function time_daemons(lists) {
	let running = {};

	for (let name, program in TIME_DAEMONS) {
		running[name] = false;

		for (let n, i in lists[name]?.[name]?.instances ?? {})
			if (i?.running === true && i.command?.[0] == program)
				running[name] = true;
	}

	return { running };
};

function failed(code, message) {
	return { error: code, message };
}

function ask(state, name, done) {
	let conn = state.conn;
	let d = conn?.defer('service', 'list', { name }, (rc, data) => done(name, rc, data));

	if (d == null) {
		let why = conn?.error() ?? 'Connection failed';

		state.conn = null;
		done(name, -1, why);
	}
}

/**
 * Whether a process runs each of TIME_DAEMONS' programs, by the first word of its command line in /proc: time_daemons()'s reply, without asking procd.
 *
 * @param {Object} fs what reads /proc: lsdir and readfile.
 * @returns {{ running: Object<string, boolean> }} whether each runs, by name.
 */
export function running_in_proc(fs) {
	let running = {};
	let names = {};

	for (let name, program in TIME_DAEMONS) {
		running[name] = false;
		names[program] = name;
	}

	for (let pid in fs.lsdir('/proc') ?? []) {
		if (!match(pid, /^[0-9]+$/))
			continue;

		let name = names[split(fs.readfile(`/proc/${pid}/cmdline`) ?? '', '\0')[0]];

		if (name != null)
			running[name] = true;
	}

	return { running };
};

/**
 * Asks procd for the `service list` of each of TIME_DAEMONS, without waiting on it, and replies time_daemons() of them; where the request has no defer(), as 25.12.0's rpcd gives it, answers running_in_proc() at once, as waiting for procd would hold rpcd.
 *
 * @param {{ conn: ?UbusConnection }} state the connection the calls go over, made again when it fails.
 * @param {function(?string, int): ?UbusConnection} connect ubus's connect(socket, timeout).
 * @param {RpcRequest} req the request, which defer() holds until procd answers, at most PROCD_SECONDS.
 * @param {Object} fs what reads /proc, for a request without defer(): lsdir and readfile.
 * @returns {*} req.defer()'s, running_in_proc()'s without defer(), or { error, message } without a connection.
 */
export function ask_time_daemons(state, connect, req, fs) {
	if (type(req.defer) != 'function')
		return running_in_proc(fs);

	state.conn ??= connect(null, PROCD_SECONDS);

	if (state.conn == null)
		return failed(errors.UBUS_CONNECT_FAILED, 'cannot connect to ubus');

	let names = keys(TIME_DAEMONS);
	let lists = {}, left = length(names), failure = null;
	let deferred = req.defer();

	function done(name, rc, data) {
		if (rc != 0)
			failure ??= failed(errors.UBUS_CALL_FAILED,
				`service list ${name}: ${(rc < 0) ? data : (UBUS_STATUS[rc] ?? `status ${rc}`)}`);
		else
			lists[name] = data;

		if (--left == 0)
			try {
				req.reply(failure ?? time_daemons(lists));
			} catch (e) {
			}
	}

	for (let name in names)
		ask(state, name, done);

	return deferred;
};

/**
 * The ubus object's methods for the collectors, which take no arguments, as rpcd serves them.
 *
 * @param {SourcesSys} sys the system, read as root in rpcd's own process.
 * @returns {Object<string, { args: Object, call: function(RpcRequest): Object }>} wireless, wireguard_peers and time_daemons.
 */
export function methods(sys) {
	let procd = { conn: null };
	let held = { key: null, reply: null };

	return {
		wireless: {
			args: {},
			call: () => wireless_held(sys, held),
		},
		wireguard_peers: {
			args: {},
			call: () => wireguard_peers(sys.cursor()),
		},
		time_daemons: {
			args: {},
			call: (req) => ask_time_daemons(procd, sys.connect, req, sys.fs),
		},
	};
};

/**
 * The system the sources' methods take, of the modules rpcd's plugin loads.
 *
 * @param {function(?string, ?string): UciCursor} cursor uci's cursor().
 * @param {Object} fs fs's lsdir, readfile, realpath and stat.
 * @param {function(?string, int): ?UbusConnection} connect ubus's connect().
 * @returns {SourcesSys} the system, its cursors on the committed configs.
 */
export function system(cursor, fs, connect) {
	return {
		cursor: () => cursor(null, NO_UCI_DELTAS),
		fs: { lsdir: fs.lsdir, readfile: fs.readfile, realpath: fs.realpath, stat: fs.stat },
		connect,
	};
};
