/**
 * The devkit's rpcd `rc` object, as a ubus mock's data.
 *
 * @module prometheus_exporter_devkit_rc
 */

'use strict';

/**
 * rc's `list` method, of the init scripts `scripts` names.
 *
 * @param {Object<string, boolean>} scripts
 * @returns {function(Object): Object}
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
 * @param {Object<string, boolean>} scripts
 * @returns {Object}
 */
export function rc(scripts) {
	return { 'rc:list': list(scripts) };
};
