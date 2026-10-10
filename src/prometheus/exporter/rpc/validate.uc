/**
 * The ubus object's `validate`: values checked as the exporter would read them.
 *
 * @module prometheus_exporter_rpc_validate
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as config from 'prometheus.exporter.config';
import { NAME } from 'prometheus.exporter.config';

/**
 * What validate answers of a value it refuses: the Problem and its English.
 *
 * @typedef {{ code: string, min: ?int, max: ?int, value: ?(int|string|string[]), message: string }} Refusal
 */

/** What malformed arguments are answered with. */
export const ARGS_INVALID = 'ARGS_INVALID';

/** The main section's options as validate takes them. */
export const MAIN_OPTIONS = [ ...keys(config.SERVICE_OPTIONS), ...keys(config.AUTH_OPTIONS), ...keys(config.MAIN_OPTIONS) ];

function is_unset(value) {
	return value == null || value === '';
}

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
 * @param {string} name
 * @param {Result} res
 * @returns {string}
 */
export function message(name, res) {
	let d = (type(res.details) == 'string') ? res.details : Result.describe(res);
	let prefix = `${name}: `;

	return (substr(d, 0, length(prefix)) == prefix) ? substr(d, length(prefix)) : d;
};

/**
 * What validate answers of a problem: it, and its English as `message`.
 *
 * @param {Problem} problem
 * @returns {Refusal}
 */
export function refusal(problem) {
	return { ...problem, message: config.english(problem) };
};

/**
 * What the exporter makes of `value` for main option `name`.
 *
 * @param {string} name
 * @param {?string} value
 * @returns {Result<(boolean|int|string)>}
 */
export function main_value(name, value) {
	if (name in keys(config.AUTH_OPTIONS))
		return is_unset(value) ? Result.ok(config.AUTH_OPTIONS[name].default) : config.convert(name, value, config.AUTH_OPTIONS[name]);

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
 * What the exporter makes of `value` for option `name` of `collector`.
 *
 * @param {Collector} collector
 * @param {string} name
 * @param {?string} value
 * @returns {Result<(boolean|int|string)>}
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
 * @param {Collector} collector
 * @returns {string[]}
 */
export function option_names(collector) {
	return [ ...keys(config.core(collector.meta, config.EXEC_TIMEOUT)), ...keys(collector.meta.options ?? {}) ];
};

/**
 * The answer to malformed arguments.
 *
 * @param {string} msg
 * @returns {{ error: string, message: string }}
 */
export function invalid_args(msg) {
	return { error: ARGS_INVALID, message: msg };
};

/**
 * What the ubus object's `validate` answers.
 *
 * @param {RpcSys} sys
 * @param {?Object} args
 * @returns {Object}
 */
export function validate(sys, args) {
	let main = args?.main ?? {};
	let given = args?.collectors ?? {};
	let errors = { main: {}, collectors: {} };
	let by_id = {};

	if (type(main) != 'object' || type(given) != 'object')
		return invalid_args('main and collectors must be objects');

	let saved = (!is_unset(main.auth_user) && is_unset(main.auth_password)) ? config.auth_values(sys.uci) : Result.ok({ auth_password: '' });
	let typed = { ...config.defaults(config.SERVICE_OPTIONS), auth_password: saved.ok ? saved.data.auth_password : '' };

	for (let name, value in main) {
		if (!(name in MAIN_OPTIONS) || is_unset(value))
			continue;

		let res = main_value(name, value);
		if (res.ok)
			typed[name] = res.data;
		else
			errors.main[name] = refusal(res.data.problem);
	}

	if (!saved.ok && is_unset(main.auth_password))
		errors.main.auth_password ??= refusal(saved.data.problem);

	for (let name, problem in config.together(typed))
		errors.main[name] ??= refusal(problem);

	for (let name in [ 'cert', 'key' ]) {
		let p = (errors.main[name] == null && typed[name] != '') ? config.tls_problem(sys.fs, typed[name]) : null;

		if (p)
			errors.main[name] = refusal(p);
	}

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
				errors.collectors[id][name] = refusal(res.data.problem);
			}
		}
	}

	let ok = !length(errors.main) && !length(errors.collectors);

	return { ok, errors };
};
