'use strict';

// The types of options (prometheus_exporter.config): a uci value as the type
// of the option's default, and the datatypes the core enforces, LuCI's names
// and its own.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as crypt from 'prometheus_exporter.crypt';
import { is_user, is_hash, ROUNDS_MAX } from 'prometheus_exporter.auth';

// The spellings of a boolean uci value, as uci's own tools take them.
export const TRUE = [ '1', 'yes', 'on', 'true', 'enabled' ];
export const FALSE = [ '0', 'no', 'off', 'false', 'disabled' ];

function absolute_path(v) {
	return substr(v, 0, 1) == '/' && !match(v, /[[:cntrl:]]/);
}

// The datatypes the core enforces, by LuCI's names: what value type each
// takes, what it calls a valid value, and whether a value is one. Syntactic
// only: a directory or file is an absolute path, not one that exists. Besides
// LuCI's, regex, and username and crypt, basic auth's user and hash. A
// datatype's `why`, when it has one, says what it expected of a value it does
// not take, instead of `expected`: crypt's, of a hash of too many rounds.
export const DATATYPES = {
	username: { types: [ 'string' ], expected: 'a user of 1 to 64 characters, without ":", spaces or control characters', check: is_user },
	crypt: {
		types: [ 'string' ],
		expected: 'a crypt hash: $1$ (uhttpd -m), $5$ or $6$',
		check: is_hash,
		why: (v) => crypt.is_hash(v)
			? `a hash of at most ${ROUNDS_MAX} rounds, which a scrape computes to check the password (hash_password makes one of 1000; one without rounds= has 5000)`
			: null,
	},
	uinteger: { types: [ 'int' ], expected: 'an integer of 0 or more', check: (v) => v >= 0 },
	directory: { types: [ 'string' ], expected: 'an absolute path', check: absolute_path },
	file: { types: [ 'string' ], expected: 'an absolute path', check: absolute_path },
	regex: {
		types: [ 'string' ],
		expected: 'a regular expression',
		check: function(v) {
			try {
				regexp(v);
				return true;
			} catch (e) {
				return false;
			}
		},
	},
};

// { types, expected, check } of a datatype name, or null for one the core does
// not know. range(min,max) takes the integers from min to max.
export function datatype(name) {
	let m = (type(name) == 'string') ? match(name, /^range\((-?[0-9]+),(-?[0-9]+)\)$/) : null;

	if (m) {
		let lo = int(m[1]), hi = int(m[2]);

		return lo <= hi ? { types: [ 'int' ], expected: `an integer from ${lo} to ${hi}`, check: (v) => v >= lo && v <= hi } : null;
	}

	return (type(name) == 'string') ? DATATYPES[name] : null;
};

// What option `spec` expected of a value it does not take: and what it got,
// unless the option is a secret.
export function invalid(name, expected, value, spec) {
	return Result.err(errors.CONFIG_INVALID,
		`${name}: expected ${expected}` + (spec?.secret ? '' : `, got ${sprintf('%J', value)}`));
};

// A uci value as the type of the option's default.
function typed(name, value, spec) {
	switch (type(spec.default)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, 'a boolean', value, spec);

	case 'int':
		if (type(value) == 'string' && match(value, /^-?[0-9]+$/))
			return Result.ok(int(value));
		return invalid(name, 'an integer', value, spec);

	case 'string':
		if (type(value) == 'string')
			return Result.ok(value);
		return invalid(name, 'a single value', value, spec);
	}

	die(`option ${name}: unsupported default ${sprintf('%J', spec.default)}`);
}

// A uci value as option `spec` ({ default, datatype, secret }) takes it.
export function convert(name, value, spec) {
	let res = typed(name, value, spec);
	let dt = (res.ok && spec.datatype != null) ? datatype(spec.datatype) : null;

	if (dt && !dt.check(res.data))
		return invalid(name, (dt.why ? dt.why(res.data) : null) ?? dt.expected, res.data, spec);

	return res;
};
