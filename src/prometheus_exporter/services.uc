/**
 * Whether a collector's subject is there: nothing to observe, or a failure.
 *
 * @module prometheus_exporter_services
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

/** An init script enabled: its service is watched. */
export const ENABLED = 'enabled';

/** An init script someone disabled: nothing to observe. */
export const DISABLED = 'disabled';

/** No such init script: nothing to observe. */
export const NOT_INSTALLED = 'not installed';

/** What libubus calls a call to an object that is not there. */
export const NOT_FOUND = 'Not found';

/**
 * A Result of ENABLED, DISABLED or NOT_INSTALLED for the init script `name`.
 *
 * @param {UbusCapability} ubus
 * @param {string} name
 * @returns {Result<string>}
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
 * Why the service `name` is not watched, or null.
 *
 * @param {UbusCapability} ubus
 * @param {string} name
 * @returns {?string}
 */
export function idle(ubus, name) {
	let res = state(ubus, name);

	return (res.ok && res.data != ENABLED) ? `${name} is ${res.data}` : null;
};

/**
 * Nothing to observe when service `name` is not watched; else `failure`.
 *
 * @param {UbusCapability} ubus
 * @param {string} name
 * @param {Result} failure
 * @returns {Result}
 */
export function unless_disabled(ubus, name, failure) {
	let why = idle(ubus, name);

	return why ? Result.none(why) : failure;
};

/**
 * Whether a ubus call failed for its object not being there.
 *
 * @param {Result} res
 * @returns {boolean}
 */
export function object_missing(res) {
	return res.ok === false && res.error == errors.UBUS_CALL_FAILED && res.data?.status == NOT_FOUND;
};
