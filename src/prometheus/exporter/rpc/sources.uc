/**
 * What the ubus object gives collectors of root's sources: the fields they read, never a secret.
 *
 * @module prometheus_exporter_rpc_sources
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';

/** The fields of a radio of netifd's wireless status that wireless() keeps. */
export const RADIO_FIELDS = [ 'up', 'disabled' ];

/** The fields of a radio's config that wireless() keeps. */
export const RADIO_CONFIG = [ 'channel', 'country', 'htmode' ];

/** The fields of a wifi-iface's config that wireless() keeps: no key, password or secret. */
export const IFACE_CONFIG = [ 'ssid', 'mesh_id', 'encryption' ];

/** The seconds the method `wireless` waits for netifd. */
export const WIRELESS_SECONDS = 3;

/** What the method `wireless` runs, apart from rpcd: netifd's status by ubus's command line, then its exit status. */
export const WIRELESS_COMMAND = `ubus -S -t ${WIRELESS_SECONDS} call network.wireless status 2>&1; echo "$?"`;

/** The exit status of ubus's command line for an object that is not there (UBUS_STATUS_NOT_FOUND). */
export const UBUS_NOT_FOUND = 4;

/** libubus's text of each status, which ubus's command line exits with and, with -S, does not print. */
export const UBUS_STATUS = [
	'Success', 'Invalid command', 'Invalid argument', 'Method not found', 'Not found', 'No response',
	'Permission denied', 'Request timed out', 'Operation not supported', 'Unknown error', 'Connection failed',
];

/** The procd services time_daemons() says of, and the program each runs. */
export const TIME_DAEMONS = { sysntpd: '/usr/sbin/ntpd', chronyd: '/usr/sbin/chronyd' };

const SCALAR = { string: true, int: true, double: true, bool: true };

function pick(obj, fields) {
	let out = {};

	for (let f in fields)
		if (SCALAR[type(obj?.[f])])
			out[f] = obj[f];

	return out;
}

function failed(res) {
	return { error: res.error, message: Result.describe(res) };
}

/**
 * netifd's `network.wireless status` with only the fields the collectors read: no key of any network.
 *
 * @param {*} status
 * @returns {{ radios: Object<string, Object> }}
 */
export function wireless(status) {
	let radios = {};

	for (let name, r in (type(status) == 'object' ? status : {})) {
		if (type(r) != 'object')
			continue;

		let interfaces = [];

		for (let i in (type(r.interfaces) == 'array' ? r.interfaces : []))
			if (type(i?.ifname) == 'string')
				push(interfaces, { ifname: i.ifname, config: pick(i.config, IFACE_CONFIG) });

		radios[name] = { ...pick(r, RADIO_FIELDS), config: pick(r.config, RADIO_CONFIG), interfaces };
	}

	return { radios };
};

/**
 * The description of each WireGuard peer of the network config, by interface and public key: nothing else of it.
 *
 * @param {UciCursor} uci
 * @returns {{ interfaces: Object<string, Object<string, string>> }}
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
 * @param {Object<string, *>} lists
 * @returns {{ running: Object<string, boolean> }}
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

/**
 * What the method `wireless` answers of WIRELESS_COMMAND's output: wireless() of netifd's status, or why not.
 *
 * @param {?string} out
 * @returns {Object}
 */
export function wireless_reply(out) {
	let text = rtrim(out ?? '', '\n');
	let i = rindex(text, '\n');
	let status = match(substr(text, i + 1), /^[0-9]+$/) ? +substr(text, i + 1) : null;
	let body = (i < 0) ? '' : trim(substr(text, 0, i));

	if (status == UBUS_NOT_FOUND)
		return { radios: {} };
	if (status != 0)
		return { error: errors.UBUS_CALL_FAILED, message: `network.wireless status: ${body || UBUS_STATUS[status] || ((status == null) ? 'no answer' : `exit status ${status}`)}` };

	try {
		return wireless(json(body));
	} catch (e) {
		return { error: errors.SOURCE_INVALID, message: 'network.wireless status: not JSON' };
	}
};

/**
 * What the method `time_daemons` answers: time_daemons() of procd's lists, asked as root.
 *
 * @param {UbusCapability} ubus
 * @returns {Object}
 */
export function time_daemons_of(ubus) {
	let lists = {};

	for (let name in keys(TIME_DAEMONS)) {
		let res = ubus.call('service', 'list', { name });

		if (!res.ok)
			return failed(res);
		lists[name] = res.data;
	}

	return time_daemons(lists);
};
