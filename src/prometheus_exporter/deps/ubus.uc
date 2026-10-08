/**
 * The ubus capability: a collector's calls of ubus objects, as Results, over
 * one connection a scrape shares (prometheus_exporter.deps' session).
 *
 * @module prometheus_exporter_deps_ubus
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

/**
 * deps.ubus: ubus_channel's object. call() and list() are a collector's;
 * limit() and close() the session's.
 *
 * @typedef {{
 *   call: (object: string, method: string, args: ?Object) => Result,
 *   list: () => Result<string[]>,
 *   limit: (t: ?float) => void,
 *   close: () => void
 * }} UbusCapability
 */

/**
 * The status of a failed ubus call: what ucode's error() puts first, libubus's
 * text for it ('Not found', 'Method not found'), before any ': ' and message.
 * error() clears the error as it reads it, so the status is taken from its text.
 *
 * @param {string} message what the connection's error() said.
 * @returns {string} its status, the text before the first ': '.
 */
export function ubus_status(message) {
	let i = index(message, ': ');

	return i < 0 ? message : substr(message, 0, i);
};

/**
 * The seconds a ubus call waits for its reply when nothing limits it: ucode's
 * own default.
 *
 * @type {int}
 */
export const UBUS_TIMEOUT = 30;

/**
 * A ubus connection opened on first use, so a scrape that needs no ubus makes
 * none. A null reply is not a failure by itself: only error() tells a method
 * without data from a failed call, whose data is { status } (ubus_status).
 *
 * limit(t): the calls after it wait for no reply past `t` (monotonic seconds,
 * clock_fn's), null for UBUS_TIMEOUT: a collector's ubus calls end by the time
 * it is stopped, so a service that does not answer fails the call, saying so,
 * rather than the collector. ucode's ubus takes one timeout per connection, in
 * whole seconds, set when it connects: a call that needs a shorter one than
 * its connection's connects again, which happens at most once a second, as a
 * scrape's time runs down, and so does the first call under a new limit that
 * allows a longer one; a call never waits less than a second.
 *
 * @param {function(?string, int): ?UbusConnection} connect_fn the ubus
 *   module's connect(socket, timeout), or a test's.
 * @param {?function(): int[]} clock_fn a monotonic clock, [ s, ns ];
 *   clock(true) when null.
 * @returns {UbusCapability} the channel.
 */
export function ubus_channel(connect_fn, clock_fn) {
	let conn = null;
	let tried = false;
	let limit = null;
	let timeout = null;
	let connected_for = null;

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
				if (e)
					return Result.err(errors.UBUS_CALL_FAILED, `${object} ${method}: ${e}`, { status: ubus_status(e) });
			}

			return Result.ok(reply);
		},

		// The names of every published object.
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
