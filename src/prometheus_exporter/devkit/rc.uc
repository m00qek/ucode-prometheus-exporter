/**
 * The devkit's rpcd `rc` object, as a ubus mock's data, for a collector that
 * tells a disabled service from a failure (the collector API's services):
 * rc({ dnsmasq: true, unbound: false }) answers `rc list { name }` as 25.12's
 * rpcd does, { <name>: { start, enabled } } for an init script the map names
 * (enabled or not), {} for any other, which is not installed. Merge it into a
 * mock's data: { ...rc({...}), 'dnsmasq:metrics': ... }.
 *
 * What it exports is what a major version of the exporter protects.
 *
 * @module prometheus_exporter_devkit_rc
 */

'use strict';

/**
 * rc's `list` method, of the init scripts `scripts` names: a function of a
 * call's arguments, as the ubus proxy takes one.
 *
 * @param {Object<string, boolean>} scripts each script, and whether it is
 *   enabled.
 * @returns {function(Object): Object} the method.
 */
export function list(scripts) {
	return function(args) {
		let name = args?.name;

		return (name in keys(scripts)) ? { [name]: { start: 19, enabled: scripts[name] } } : {};
	};
};

/**
 * A ubus mock's data of rc's `list`, for the init scripts `scripts` names.
 *
 * @param {Object<string, boolean>} scripts each script, and whether it is
 *   enabled.
 * @returns {Object} the data, { 'rc:list': list(scripts) }.
 */
export function rc(scripts) {
	return { 'rc:list': list(scripts) };
};
