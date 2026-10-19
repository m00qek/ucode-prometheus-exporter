/**
 * What is wrong with an option's value, as a code and its arguments: a Problem.
 *
 * @module prometheus_exporter_config_problems
 */

'use strict';

/**
 * A problem with an option's value: its code, one of CODES, its arguments and the value read.
 *
 * @typedef {{ code: string, min: ?int, max: ?int, value: ?(int|string|string[]) }} Problem
 */

/**
 * What a code takes and says: its arguments, whether it is of a value, and its English.
 *
 * @typedef {{ args: string[], value: boolean, text: function(Problem): string }} ProblemCode
 */

/**
 * Not one of uci's spellings of a boolean.
 *
 * @type {string}
 */
export const BOOLEAN = 'BOOLEAN';

/**
 * Not an integer: decimal digits, with an optional '-'.
 *
 * @type {string}
 */
export const INTEGER = 'INTEGER';

/**
 * A list, where the option takes a single value.
 *
 * @type {string}
 */
export const SINGLE = 'SINGLE';

/**
 * An integer outside `min` to `max`: the datatype range(min,max).
 *
 * @type {string}
 */
export const RANGE = 'RANGE';

/**
 * An integer under 0: the datatype uinteger.
 *
 * @type {string}
 */
export const UINTEGER = 'UINTEGER';

/**
 * An integer that is neither 0 nor `min` or more: the datatype zero_or_min(min).
 *
 * @type {string}
 */
export const ZERO_OR_MIN = 'ZERO_OR_MIN';

/**
 * Not an absolute path: the datatypes directory and file.
 *
 * @type {string}
 */
export const ABSOLUTE_PATH = 'ABSOLUTE_PATH';

/**
 * Not a directory the service may make and mount for a collector: the datatype owned_directory.
 *
 * @type {string}
 */
export const OWNED_DIRECTORY = 'OWNED_DIRECTORY';

/**
 * Not a path the service copies a TLS file from: the datatype tls_file.
 *
 * @type {string}
 */
export const TLS_PATH = 'TLS_PATH';

/**
 * A TLS file there that is not a regular file of at most `max` bytes, or whose links lead elsewhere.
 *
 * @type {string}
 */
export const TLS_FILE = 'TLS_FILE';

/**
 * Not a regular expression regexp() compiles: the datatype regex.
 *
 * @type {string}
 */
export const REGEX = 'REGEX';

/**
 * Not an IPv4 or IPv6 address, without a prefix length: the datatype ipaddr.
 *
 * @type {string}
 */
export const IPADDR = 'IPADDR';

/**
 * Not a user basic auth takes: the datatype username.
 *
 * @type {string}
 */
export const USERNAME = 'USERNAME';

/**
 * Not a crypt hash basic auth takes: the datatype crypt.
 *
 * @type {string}
 */
export const CRYPT = 'CRYPT';

/**
 * A crypt hash of more rounds than `max`: the datatype crypt.
 *
 * @type {string}
 */
export const CRYPT_ROUNDS = 'CRYPT_ROUNDS';

/**
 * An empty listen_interface.
 *
 * @type {string}
 */
export const INTERFACE = 'INTERFACE';

/**
 * auth_user without auth_password.
 *
 * @type {string}
 */
export const AUTH_NEEDS_PASSWORD = 'AUTH_NEEDS_PASSWORD';

/**
 * Basic auth without cert and key: Basic sends the password in the clear.
 *
 * @type {string}
 */
export const AUTH_NEEDS_TLS = 'AUTH_NEEDS_TLS';

/**
 * Every code, with what it takes and says: the closed set of problems.
 *
 * @type {Object<string, ProblemCode>}
 */
export const CODES = {
	[BOOLEAN]: { args: [], value: true, text: () => 'a boolean' },
	[INTEGER]: { args: [], value: true, text: () => 'an integer' },
	[SINGLE]: { args: [], value: true, text: () => 'a single value' },
	[RANGE]: { args: [ 'min', 'max' ], value: true, text: (p) => `an integer from ${p.min} to ${p.max}` },
	[UINTEGER]: { args: [], value: true, text: () => 'an integer of 0 or more' },
	[ZERO_OR_MIN]: { args: [ 'min' ], value: true, text: (p) => `0, or an integer of ${p.min} or more` },
	[ABSOLUTE_PATH]: { args: [], value: true, text: () => 'an absolute path' },
	[OWNED_DIRECTORY]: {
		args: [], value: true,
		text: () => 'a directory under /var, /tmp or /etc/prometheus-exporter, and not under /var/run or /tmp/run, which the service makes and mounts',
	},
	[TLS_PATH]: {
		args: [], value: true,
		text: () => 'a file under /etc/ssl, /etc/acme or /etc/prometheus-exporter, or uhttpd\'s own, /etc/uhttpd.*',
	},
	[TLS_FILE]: {
		args: [ 'max' ], value: true,
		text: (p) => `a regular file of at most ${p.max} bytes, which its links, if any, leave under /etc/ssl, /etc/acme, /etc/prometheus-exporter or /etc/uhttpd.*`,
	},
	[REGEX]: { args: [], value: true, text: () => 'a regular expression' },
	[IPADDR]: { args: [], value: true, text: () => 'an IPv4 or IPv6 address' },
	[USERNAME]: { args: [], value: true, text: () => 'a user of 1 to 64 characters, without ":", spaces or control characters' },
	[CRYPT]: { args: [], value: true, text: () => 'a crypt hash: $1$ (uhttpd -m), $5$ or $6$' },
	[CRYPT_ROUNDS]: {
		args: [ 'max' ], value: true,
		text: (p) => `a hash of at most ${p.max} rounds, which a scrape computes to check the password ` +
			'(hash_password makes one of 1000; one without rounds= has 5000)',
	},
	[INTERFACE]: { args: [], value: true, text: () => 'an interface name or *' },
	[AUTH_NEEDS_PASSWORD]: { args: [], value: false, text: () => 'basic auth needs the hash of a password along with auth_user' },
	[AUTH_NEEDS_TLS]: {
		args: [], value: false,
		text: () => 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
	},
};

/**
 * A Problem of `code`, with its arguments and, for a code of a value, the value.
 *
 * @param {string} code one of CODES.
 * @param {?Object} args its args, and `value` of a value's code unless the option is a secret.
 * @returns {Problem} { code, ...args }.
 */
export function problem(code, args) {
	let c = CODES[code];

	if (c == null)
		die(`unknown problem code ${sprintf('%J', code)}`);

	for (let k in keys(args ?? {}))
		if (!(k in c.args) && !(k == 'value' && c.value))
			die(`problem ${code} takes no ${k}`);

	return { code, ...(args ?? {}) };
};

/**
 * What a value's code expected, without what it got: 'an integer from 1 to 30'.
 *
 * @param {Problem} p the problem.
 * @returns {string} what the option expected.
 */
export function expected(p) {
	return CODES[p.code].text(p);
};

/**
 * A problem in English, without the option's name: 'expected ..., got ...'.
 *
 * @param {Problem} p the problem.
 * @returns {string} the English.
 */
export function english(p) {
	let c = CODES[p.code];

	if (!c.value)
		return c.text(p);

	return `expected ${c.text(p)}` + (('value' in p) ? `, got ${sprintf('%J', p.value)}` : '');
};

/**
 * A problem in English, after the option's name: what a CONFIG_INVALID's details say.
 *
 * @param {string} name the option's name.
 * @param {Problem} p the problem.
 * @returns {string} 'name: ' and its English.
 */
export function message(name, p) {
	return `${name}: ${english(p)}`;
};
