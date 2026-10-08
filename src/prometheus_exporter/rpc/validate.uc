/**
 * The ubus object's `validate`: values checked as the exporter would read
 * them (prometheus_exporter.rpc).
 *
 * validate takes values as uci holds them (strings) and checks each alone, as
 * the exporter would read it: an empty or missing value is unset. Options nobody
 * declared, and collectors that are not installed, are ignored, as the exporter
 * ignores them. The main section's options that go together (basic auth's user
 * and hash, which need cert and key) are checked as if the values given were the
 * whole section. A message never holds auth_password's value. Malformed
 * arguments are answered { error: ARGS_INVALID, message }.
 *
 * @module prometheus_exporter_rpc_validate
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import { NAME } from 'prometheus_exporter.config';

/**
 * What malformed arguments are answered with.
 *
 * @type {string}
 */
export const ARGS_INVALID = 'ARGS_INVALID';

/**
 * The main section's options: the init script's, then the exporter's.
 *
 * @type {string[]}
 */
export const MAIN_OPTIONS = [ ...keys(config.SERVICE_OPTIONS), ...keys(config.MAIN_OPTIONS) ];

function is_unset(value) {
	return value == null || value === '';
}

// A cursor over the exporter's config with one section, holding `values`: what
// the exporter would read of those values alone.
function lone_section(name, stype, values) {
	let s = { '.name': name, '.type': stype, '.anonymous': false };

	for (let k, v in values)
		if (!is_unset(v))
			s[k] = v;

	let get_all = (pkg, sid) => (pkg == NAME && sid == name) ? s : null;

	return {
		load: (pkg) => pkg == NAME,
		get_all,
		get: (pkg, sid, opt) => (opt == null) ? get_all(pkg, sid)?.['.type'] : get_all(pkg, sid)?.[opt],
		foreach: function(pkg, t, cb) {
			if (pkg == NAME && (t == null || t == stype))
				cb(s);
		},
	};
}

/**
 * The details of a CONFIG_INVALID, less the option's name the field already shows.
 *
 * @param {string} name the option's name.
 * @param {Result} res the failed Result.
 * @returns {string} its details, less 'name: '.
 */
export function message(name, res) {
	let d = (type(res.details) == 'string') ? res.details : Result.describe(res);
	let prefix = `${name}: `;

	return (substr(d, 0, length(prefix)) == prefix) ? substr(d, length(prefix)) : d;
};

/**
 * What the exporter makes of `value` for option `name` of the main section:
 * a Result of the typed value, the default when it is unset.
 *
 * @param {string} name the option's name.
 * @param {?string} value its value, as uci holds it.
 * @returns {Result<(boolean|int|string)>} the typed value, or
 *   CONFIG_INVALID.
 */
export function main_value(name, value) {
	let uci = lone_section('main', NAME, { [name]: value });
	let svc = config.service_values(uci);
	let own = config.main(uci);

	if (!svc.ok)
		return svc;
	if (!own.ok)
		return own;

	return Result.ok((name in keys(config.SERVICE_OPTIONS)) ? svc.data[name] : own.data[name]);
};

/**
 * What the exporter makes of `value` for option `name` (or the core's enabled
 * or timeout) of collector `collector`: a Result of the typed value, the default when
 * it is unset. The section is read alone: an unset timeout is meta.timeout's,
 * or exec_timeout's default.
 *
 * @param {Collector} collector the collector.
 * @param {string} name the option's name.
 * @param {?string} value its value, as uci holds it.
 * @returns {Result<(boolean|int|string)>} the typed value, or
 *   CONFIG_INVALID.
 */
export function collector_value(collector, name, value) {
	let uci = lone_section(collector.id, 'collector', { [name]: value });
	let res = config.settings(uci, collector.id, collector.meta);

	if (!res.ok)
		return res;

	switch (name) {
	case 'enabled': return Result.ok(config.enabled(uci, collector.id));
	case 'timeout': return Result.ok(res.data.timeout);
	}

	return Result.ok(res.data.options[name]);
};

/**
 * The option names a collector's section takes: the core's, then its own.
 *
 * @param {Collector} collector the collector.
 * @returns {string[]} the names.
 */
export function option_names(collector) {
	return [ ...keys(config.core(collector.meta, config.EXEC_TIMEOUT)), ...keys(collector.meta.options ?? {}) ];
};

/**
 * The answer to malformed arguments.
 *
 * @param {string} msg what is wrong.
 * @returns {{ error: string, message: string }} { error: ARGS_INVALID,
 *   message }.
 */
export function invalid_args(msg) {
	return { error: ARGS_INVALID, message: msg };
};

/**
 * What the ubus object's `validate` answers, as the module's top comment
 * says.
 *
 * @param {RpcSys} sys the system: its collectors.
 * @param {?Object} args the method's arguments: { main, collectors }.
 * @returns {Object} { ok, errors: { main: { option: message }, collectors:
 *   { id: { option: message } } } }, or { error: ARGS_INVALID, message }.
 */
export function validate(sys, args) {
	let main = args?.main ?? {};
	let given = args?.collectors ?? {};
	let errors = { main: {}, collectors: {} };
	let by_id = {};

	if (type(main) != 'object' || type(given) != 'object')
		return invalid_args('main and collectors must be objects');

	let typed = config.defaults(config.SERVICE_OPTIONS);

	for (let name, value in main) {
		if (!(name in MAIN_OPTIONS) || is_unset(value))
			continue;

		let res = main_value(name, value);
		if (res.ok)
			typed[name] = res.data;
		else
			errors.main[name] = message(name, res);
	}

	for (let name, msg in config.together(typed))
		errors.main[name] ??= msg;

	for (let c in sys.collectors)
		by_id[c.id] = c;

	for (let id, values in given) {
		let c = by_id[id];

		if (c == null)
			continue;
		if (type(values) != 'object')
			return invalid_args(`collectors.${id} must be an object`);

		let names = option_names(c);

		for (let name, value in values) {
			if (!(name in names) || is_unset(value))
				continue;

			let res = collector_value(c, name, value);
			if (!res.ok) {
				errors.collectors[id] ??= {};
				errors.collectors[id][name] = message(name, res);
			}
		}
	}

	let ok = !length(errors.main) && !length(errors.collectors);

	return { ok, errors };
};
