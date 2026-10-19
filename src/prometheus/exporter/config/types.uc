/**
 * The types of options: uci values typed as their defaults, and the datatypes the core enforces.
 *
 * @module prometheus_exporter_config_types
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as problems from 'prometheus.exporter.config.problems';
import { is_user, is_hash, is_auth_hash, AUTH_ROUNDS_MAX } from 'prometheus.exporter.hashes';

/**
 * A datatype the core enforces: the value types it takes, its problem, and its check.
 *
 * @typedef {{
 *   types: string[],
 *   problem: Problem,
 *   expected: string,
 *   check: function((boolean|int|string)): boolean,
 *   why: ?function((boolean|int|string)): ?Problem
 * }} Datatype
 */

/**
 * The spellings of true.
 *
 * @type {string[]}
 */
export const TRUE = [ '1', 'yes', 'on', 'true', 'enabled' ];

/**
 * The spellings of false.
 *
 * @type {string[]}
 */
export const FALSE = [ '0', 'no', 'off', 'false', 'disabled' ];

function absolute_path(v) {
	return substr(v, 0, 1) == '/' && !match(v, /[[:cntrl:]]/);
}

/**
 * The directories under which the service makes and mounts a collector's own directories.
 *
 * @type {string[]}
 */
export const OWNED_ROOTS = [ '/var', '/tmp', '/etc/prometheus-exporter' ];

/**
 * The run directories of every service, under OWNED_ROOTS, where an option names no directory of its own.
 *
 * @type {string[]}
 */
export const RUN_ROOTS = [ '/var/run', '/tmp/run' ];

function under(p, roots) {
	for (let root in roots)
		if (length(p) > length(root) + 1 && substr(p, 0, length(root) + 1) == `${root}/`)
			return true;

	return false;
}

/**
 * Whether `v` is a directory the service may make and mount as a collector's own.
 *
 * @param {*} v anything; only a string is a directory.
 * @returns {boolean} whether it is one.
 */
export function is_owned_directory(v) {
	if (type(v) != 'string' || !absolute_path(v) || match(v, /\/\.\.?(\/|$)/))
		return false;

	let p = rtrim(v, '/');

	return under(p, OWNED_ROOTS) && !under(p, RUN_ROOTS) && !(p in RUN_ROOTS);
};

/**
 * The directories `cert` and `key` may be under: where certificates are kept, and the exporter's own.
 *
 * @type {string[]}
 */
export const TLS_DIRS = [ '/etc/ssl', '/etc/acme', '/etc/prometheus-exporter' ];

/**
 * The most bytes the service copies of `cert` or `key`.
 *
 * @type {int}
 */
export const TLS_FILE_MAX = 65536;

const UHTTPD_FILE = /^\/etc\/uhttpd[A-Za-z0-9._-]*$/;

/**
 * Whether `v` is a path the service may copy a TLS file from: under TLS_DIRS, or uhttpd's own /etc/uhttpd.*.
 *
 * @param {*} v the path, of any type.
 * @returns {boolean} whether the service may copy a TLS file from it.
 */
export function is_tls_path(v) {
	if (type(v) != 'string' || !absolute_path(v) || match(v, /\/\/|\/\.\.?(\/|$)|\/$/))
		return false;
	if (match(v, UHTTPD_FILE))
		return true;

	for (let d in TLS_DIRS)
		if (length(v) > length(d) + 1 && substr(v, 0, length(d) + 1) == `${d}/`)
			return true;

	return false;
};

/**
 * The TLS_FILE problem of the TLS file at `path`, or null: not a regular file of at most TLS_FILE_MAX bytes, or its links lead past is_tls_path(). A file not there is none.
 *
 * @param {module:fs} fs the fs module, or an object of its stat and realpath.
 * @param {string} path the TLS file's path.
 * @returns {?Problem} TLS_FILE, or null when it is fine or not there.
 */
export function tls_problem(fs, path) {
	let st = fs.stat(path);

	if (st == null)
		return null;

	let real = fs.realpath ? fs.realpath(path) : path;

	if (st.type != 'file' || st.size > TLS_FILE_MAX || !is_tls_path(real))
		return problems.problem(problems.TLS_FILE, { max: TLS_FILE_MAX, value: path });

	return null;
};

function datatype_of(types, code, args, check, why) {
	let p = problems.problem(code, args);

	return { types, problem: p, expected: problems.expected(p), check, why };
}

/**
 * The datatypes the core enforces, by LuCI's names, and its own.
 *
 * @type {Object<string, Datatype>}
 */
export const DATATYPES = {
	username: datatype_of([ 'string' ], problems.USERNAME, null, is_user),
	crypt: datatype_of([ 'string' ], problems.CRYPT, null, is_auth_hash,
		(v) => is_hash(v) ? problems.problem(problems.CRYPT_ROUNDS, { max: AUTH_ROUNDS_MAX }) : null),
	uinteger: datatype_of([ 'int' ], problems.UINTEGER, null, (v) => v >= 0),
	directory: datatype_of([ 'string' ], problems.ABSOLUTE_PATH, null, absolute_path),
	file: datatype_of([ 'string' ], problems.ABSOLUTE_PATH, null, absolute_path),
	owned_directory: datatype_of([ 'string' ], problems.OWNED_DIRECTORY, null, is_owned_directory),
	tls_file: datatype_of([ 'string' ], problems.TLS_PATH, null, (v) => v == '' || is_tls_path(v)),
	regex: datatype_of([ 'string' ], problems.REGEX, null, function(v) {
		try {
			regexp(v);
			return true;
		} catch (e) {
			return false;
		}
	}),
};

const RANGES = {};
const RANGES_MAX = 256;

function range_of(lo, hi) {
	return datatype_of([ 'int' ], problems.RANGE, { min: lo, max: hi }, (v) => v >= lo && v <= hi);
}

function zero_or_min_of(lo) {
	return datatype_of([ 'int' ], problems.ZERO_OR_MIN, { min: lo }, (v) => v == 0 || v >= lo);
}

/**
 * { types, problem, expected, check } of a datatype name, or null for one the core does not know.
 *
 * @param {*} name the datatype's name; anything but a string is none.
 * @returns {?Datatype} the datatype, or null.
 */
export function datatype(name) {
	if (type(name) != 'string')
		return null;

	let known = DATATYPES[name] ?? RANGES[name];

	if (known)
		return known;

	let z = match(name, /^zero_or_min\(([1-9][0-9]*)\)$/);

	if (z) {
		if (length(RANGES) < RANGES_MAX)
			RANGES[name] = zero_or_min_of(int(z[1]));

		return RANGES[name] ?? zero_or_min_of(int(z[1]));
	}

	let m = match(name, /^range\((-?[0-9]+),(-?[0-9]+)\)$/);

	if (!m)
		return null;

	let lo = int(m[1]), hi = int(m[2]);

	if (lo > hi)
		return null;

	if (length(RANGES) < RANGES_MAX)
		RANGES[name] = range_of(lo, hi);

	return RANGES[name] ?? range_of(lo, hi);
};

/**
 * The CONFIG_INVALID of a value option `spec` does not take.
 *
 * @param {string} name the option's name.
 * @param {Problem} problem what is wrong with the value, without it.
 * @param {*} value what it got: a uci value, or one typed already.
 * @param {?OptionSpec} spec the option; its `secret` keeps the value out.
 * @returns {Result} CONFIG_INVALID.
 */
export function invalid(name, problem, value, spec) {
	let p = spec?.secret ? problem : { ...problem, value };

	return Result.err(errors.CONFIG_INVALID, problems.message(name, p), { option: name, problem: p });
};

const INTEGER = /^-?[0-9]+$/;

function typed(name, value, spec) {
	switch (type(spec.default)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, problems.problem(problems.BOOLEAN), value, spec);

	case 'int':
		if (type(value) == 'string' && match(value, INTEGER))
			return Result.ok(int(value));
		return invalid(name, problems.problem(problems.INTEGER), value, spec);

	case 'string':
		if (type(value) == 'string')
			return Result.ok(value);
		return invalid(name, problems.problem(problems.SINGLE), value, spec);
	}

	die(`option ${name}: unsupported default ${sprintf('%J', spec.default)}`);
}

/**
 * A uci value as option `spec` ({ default, datatype, secret }) takes it.
 *
 * @param {string} name the option's name.
 * @param {?(string|string[])} value the uci value.
 * @param {OptionSpec} spec the option.
 * @returns {Result<(boolean|int|string)>} the value, typed, or CONFIG_INVALID.
 */
export function convert(name, value, spec) {
	let res = typed(name, value, spec);
	let dt = (res.ok && spec.datatype != null) ? datatype(spec.datatype) : null;

	if (dt && !dt.check(res.data))
		return invalid(name, (dt.why ? dt.why(res.data) : null) ?? dt.problem, res.data, spec);

	return res;
};
