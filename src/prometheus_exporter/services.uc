/**
 * Whether a collector's subject is there, for the collectors to tell nothing
 * to observe (Result.none) from a failure, over their deps.ubus:
 *
 * - a service is watched only while its init script is enabled: one someone
 *   disabled (`/etc/init.d/<name> disable`), or never installed, is nothing to
 *   observe; one enabled that does not answer is a failure. rpcd's rc object
 *   says which: `rc list { name, skip_running_check }` answers
 *   { <name>: { start, stop, enabled } } for an init script, {} for none, and
 *   skips the `<script> running` it would run otherwise. rpcd reads
 *   /etc/init.d and /etc/rc.d itself, outside the exporter's jail, which
 *   reaches it through the ubus socket it has.
 * - a ubus object that is not there (a device without DSL has no `dsl`) fails
 *   a call with libubus's 'Not found' (deps.ubus_status).
 *
 * The check is made once a collector's own source fails, so a scrape of a
 * running service asks rc nothing.
 *
 * @module prometheus_exporter_services
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

/**
 * An init script enabled: its service is watched.
 *
 * @type {string}
 */
export const ENABLED = 'enabled';

/**
 * An init script someone disabled: nothing to observe.
 *
 * @type {string}
 */
export const DISABLED = 'disabled';

/**
 * No such init script: nothing to observe.
 *
 * @type {string}
 */
export const NOT_INSTALLED = 'not installed';

/**
 * What libubus calls a call to an object that is not there.
 *
 * @type {string}
 */
export const NOT_FOUND = 'Not found';

/**
 * A Result of ENABLED, DISABLED or NOT_INSTALLED for the init script `name`,
 * as rpcd's rc object says; its error when rc cannot be asked.
 *
 * @param {UbusCapability} ubus the collector's deps.ubus.
 * @param {string} name the init script's name.
 * @returns {Result<string>} ENABLED, DISABLED or NOT_INSTALLED.
 */
export function state(ubus, name) {
	let res = ubus.call('rc', 'list', { name, skip_running_check: true });

	if (!res.ok)
		return res;
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'rc list: not an object');

	let script = res.data[name];

	if (script == null)
		return Result.ok(NOT_INSTALLED);
	if (type(script) != 'object' || type(script.enabled) != 'bool')
		return Result.err(errors.SOURCE_INVALID, `rc list: ${name}: no enabled`);

	return Result.ok(script.enabled ? ENABLED : DISABLED);
};

/**
 * Why the service `name` is not watched ('dnsmasq is disabled', 'dawn is not
 * installed'), or null while it is enabled, or rc cannot say.
 *
 * @param {UbusCapability} ubus the collector's deps.ubus.
 * @param {string} name the init script's name.
 * @returns {?string} '<name> is disabled' or '<name> is not installed', or
 *   null.
 */
export function idle(ubus, name) {
	let res = state(ubus, name);

	return (res.ok && res.data != ENABLED) ? `${name} is ${res.data}` : null;
};

/**
 * Nothing to observe when the service `name` is not watched; `failure`, what
 * its source failed with, while it is enabled or rc cannot say.
 *
 * @param {UbusCapability} ubus the collector's deps.ubus.
 * @param {string} name the init script's name.
 * @param {Result} failure what the collector's source failed with.
 * @returns {Result} Result.none(why), or `failure`.
 */
export function unless_disabled(ubus, name, failure) {
	let why = idle(ubus, name);

	return why ? Result.none(why) : failure;
};

/**
 * Whether a ubus call failed for its object not being there.
 *
 * @param {Result} res a ubus call's Result.
 * @returns {boolean} whether it is UBUS_CALL_FAILED with the status
 *   NOT_FOUND.
 */
export function object_missing(res) {
	return res.ok === false && res.error == errors.UBUS_CALL_FAILED && res.data?.status == NOT_FOUND;
};
