/**
 * The ubus capability: a collector's ubus calls, as Results, over a scrape's connection.
 *
 * @module prometheus_exporter_deps_ubus
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import { allows, CANARY, ACL_LINK } from 'prometheus.exporter.privileges';

/**
 * deps.ubus: ubus_channel's object.
 *
 * @typedef {{
 *   call: (object: string, method: string, args: ?Object) => Result,
 *   list: () => Result<string[]>,
 *   limit: (t: ?float) => void,
 *   close: () => void
 * }} UbusCapability
 */

/**
 * The status of a failed ubus call: libubus's text, before any ': '.
 *
 * @param {string} message what the connection's error() said.
 * @returns {string} its status, the text before the first ': '.
 */
export function ubus_status(message) {
	let i = index(message, ': ');

	return i < 0 ? message : substr(message, 0, i);
};

/**
 * libubus's text for a method the ubusd ACL refuses.
 *
 * @type {string}
 */
export const DENIED = 'Permission denied';

/**
 * libubus's text for an object that is not there, or that the ACL allows nothing of.
 *
 * @type {string}
 */
export const NOT_FOUND = 'Not found';

/**
 * The seconds a ubus call waits for its reply when nothing limits it: ucode's own default.
 *
 * @type {int}
 */
export const UBUS_TIMEOUT = 30;

/**
 * A ubus connection opened on first use, so a scrape that needs no ubus makes none.
 *
 * @param {function(?string, int): ?UbusConnection} connect_fn ubus's connect(socket, timeout).
 * @param {?function(): int[]} clock_fn a monotonic clock, [ s, ns ]; clock(true) when null.
 * @returns {UbusCapability} the channel.
 */
export function ubus_channel(connect_fn, clock_fn) {
	let conn = null;
	let tried = false;
	let limit = null;
	let timeout = null;
	let connected_for = null;
	let acl = null;

	clock_fn ??= () => clock(true);

	function seconds_left() {
		if (limit == null)
			return UBUS_TIMEOUT;

		let t = clock_fn();
		let left = limit - (t[0] + t[1] / 1000000000.0);

		return min(UBUS_TIMEOUT, max(1, int(left + 0.999)));
	}

	function get() {
		let want = seconds_left();

		if (tried && conn && (want < timeout || (want > timeout && limit != connected_for))) {
			conn.disconnect();
			conn = null;
			tried = false;
		}

		if (!tried) {
			tried = true;
			timeout = want;
			connected_for = limit;
			acl = null;
			conn = connect_fn(null, want);
		}

		return conn;
	}

	return {
		call: function(object, method, args) {
			let c = get();

			if (!c)
				return Result.err(errors.UBUS_CONNECT_FAILED);

			let reply = c.call(object, method, args ?? {});
			if (reply === null) {
				let e = c.error();
				let status = e ? ubus_status(e) : null;

				if (status == DENIED)
					return Result.err(errors.PERMISSION_DENIED, `${object} ${method}: ${status}: the service's ubus ACL does not allow it`, { status });
				if (status == NOT_FOUND && !(acl ??= (length(c.list(CANARY.object) ?? []) > 0)))
					return Result.err(errors.PERMISSION_DENIED, `${object} ${method}: ${status}: ubusd has not loaded the service's ACL (${ACL_LINK})`, { status });
				if (e)
					return Result.err(errors.UBUS_CALL_FAILED, `${object} ${method}: ${e}`, { status });
			}

			return Result.ok(reply);
		},

		list: function() {
			let c = get();

			if (!c)
				return Result.err(errors.UBUS_CONNECT_FAILED);

			let names = c.list();
			return names == null
				? Result.err(errors.UBUS_CALL_FAILED, `list: ${c.error()}`)
				: Result.ok(names);
		},

		limit: function(t) {
			limit = t;
		},

		close: function() {
			conn?.disconnect();
			conn = null;
			tried = false;
		},
	};
};

/**
 * A collector's deps.ubus: `channel`, refusing a call `declared` does not allow.
 *
 * @param {UbusCapability} channel the scrape's channel (ubus_channel's).
 * @param {Object<string, string[]>} declared the calls it may make (privileges.ubus_of's).
 * @returns {UbusCapability} the collector's.
 */
export function ubus_for(channel, declared) {
	return {
		...channel,
		call: function(object, method, args) {
			if (!allows(declared, object, method))
				return Result.err(errors.UBUS_NOT_ALLOWED, `${object} ${method}: not in meta.ubus`);

			return channel.call(object, method, args);
		},
	};
};

/**
 * The ubus module, loaded by name at run time; null when it does not load.
 *
 * @returns {?{ connect: function(?string, ?int): ?Object }} its connect; null if it does not load.
 */
export function load_ubus() {
	try {
		return loadstring("import { connect } from 'ubus';\nreturn { connect };", { raw_mode: true })();
	} catch (e) {
		return null;
	}
};
