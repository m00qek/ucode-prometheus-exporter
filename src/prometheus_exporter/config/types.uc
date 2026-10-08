/**
 * The types of options (prometheus_exporter.config): a uci value as the type
 * of the option's default, and the datatypes the core enforces, LuCI's names
 * and its own.
 *
 * @module prometheus_exporter_config_types
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as crypt from 'prometheus_exporter.crypt';
import * as problems from 'prometheus_exporter.config.problems';
import { is_user, is_hash, ROUNDS_MAX } from 'prometheus_exporter.auth';

/**
 * A datatype the core enforces: the value types it takes, the problem of a
 * value it does not take (prometheus_exporter.config.problems), what it calls
 * a valid value (that problem's `expected`), whether a value is one, and, for
 * some, a problem of a value it does not take instead of `problem`. check()
 * and why() take the option's value, typed: a boolean, an integer or a
 * string.
 *
 * @typedef {{
 *   types: string[],
 *   problem: Problem,
 *   expected: string,
 *   check: function((boolean|int|string)): boolean,
 *   why: ?function((boolean|int|string)): ?Problem
 * }} Datatype
 */

// The spellings of a boolean uci value, as uci's own tools take them.

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

// A datatype of these types whose values check() takes, and the problem of
// one it does not; why(), when given, a problem of it instead.
function datatype_of(types, code, args, check, why) {
	let p = problems.problem(code, args);

	return { types, problem: p, expected: problems.expected(p), check, why };
}

/**
 * The datatypes the core enforces, by LuCI's names: what value type each
 * takes, the problem of a value it does not take and what it calls a valid
 * value, and whether a value is one. Syntactic only: a directory or file is
 * an absolute path, not one that exists. Besides LuCI's, regex, and username
 * and crypt, basic auth's user and hash. A datatype's `why`, when it has one,
 * gives the problem of a value it does not take, instead of `problem`:
 * crypt's, of a hash of too many rounds.
 *
 * @type {Object<string, Datatype>}
 */
export const DATATYPES = {
	username: datatype_of([ 'string' ], problems.USERNAME, null, is_user),
	crypt: datatype_of([ 'string' ], problems.CRYPT, null, is_hash,
		(v) => crypt.is_hash(v) ? problems.problem(problems.CRYPT_ROUNDS, { max: ROUNDS_MAX }) : null),
	uinteger: datatype_of([ 'int' ], problems.UINTEGER, null, (v) => v >= 0),
	directory: datatype_of([ 'string' ], problems.ABSOLUTE_PATH, null, absolute_path),
	file: datatype_of([ 'string' ], problems.ABSOLUTE_PATH, null, absolute_path),
	regex: datatype_of([ 'string' ], problems.REGEX, null, function(v) {
		try {
			regexp(v);
			return true;
		} catch (e) {
			return false;
		}
	}),
};

// The range(min,max) datatypes made so far, by name: making one writes its
// problem's English, which costs a scrape more than checking every value it
// reads. At most RANGES_MAX, the few the core and the collectors declare.
const RANGES = {};
const RANGES_MAX = 256;

function range_of(lo, hi) {
	return datatype_of([ 'int' ], problems.RANGE, { min: lo, max: hi }, (v) => v >= lo && v <= hi);
}

/**
 * { types, problem, expected, check } of a datatype name, or null for one the
 * core does not know. range(min,max) takes the integers from min to max.
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

	let m = match(name, /^range\((-?[0-9]+),(-?[0-9]+)\)$/);

	if (!m)
		return null;

	let lo = int(m[1]), hi = int(m[2]);

	if (lo > hi)
		return null;

	// A scrape checks every collector's budget and max_samples by theirs.
	if (length(RANGES) < RANGES_MAX)
		RANGES[name] = range_of(lo, hi);

	return RANGES[name] ?? range_of(lo, hi);
};

/**
 * The CONFIG_INVALID of a value option `spec` does not take: its problem, with
 * the value unless the option is a secret, in English in the details, and as
 * it is in the data, { option, problem }, for what says it otherwise (the
 * ubus object's validate).
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

// A uci value as the type of the option's default.
function typed(name, value, spec) {
	switch (type(spec.default)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, problems.problem(problems.BOOLEAN), value, spec);

	case 'int':
		if (type(value) == 'string' && match(value, /^-?[0-9]+$/))
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
 * @returns {Result<(boolean|int|string)>} the value, typed, or
 *   CONFIG_INVALID.
 */
export function convert(name, value, spec) {
	let res = typed(name, value, spec);
	let dt = (res.ok && spec.datatype != null) ? datatype(spec.datatype) : null;

	if (dt && !dt.check(res.data))
		return invalid(name, (dt.why ? dt.why(res.data) : null) ?? dt.problem, res.data, spec);

	return res;
};
