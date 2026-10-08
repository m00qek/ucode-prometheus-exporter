/**
 * What is wrong with an option's value, as a code and its arguments: a
 * Problem (prometheus_exporter.config). The core says each in English from
 * here alone (english), in the log, `check`, the command line and the
 * Results of the config's functions; the ubus object's `validate` answers
 * the Problem itself, with that English as its `message`, and LuCI says it
 * in the user's language by its code. So the English and LuCI's sentences
 * never drift: a code is added here, with its English, and to LuCI's
 * sentences, where a test holds the two to the same codes.
 *
 * The codes are a closed set, CODES: those of a value an option does not
 * take, which say what the option expected, and those of options that go
 * together, which hold no value.
 *
 * @module prometheus_exporter_config_problems
 */

'use strict';

/**
 * A problem with an option's value: its code, one of CODES, the arguments
 * the code takes (`min` and `max` of RANGE, `max` of CRYPT_ROUNDS), and
 * `value`, what the exporter read: a string, an integer (RANGE's and
 * UINTEGER's) or a list (SINGLE's, or a list where a boolean or an integer
 * was expected). A secret option's problem has no value, nor has one of
 * options that go together.
 *
 * @typedef {{ code: string, min: ?int, max: ?int, value: ?(int|string|string[]) }} Problem
 */

/**
 * What a code takes and says: the arguments it holds besides `value`,
 * whether it is of a value the option does not take (which says what the
 * option expected, and what it got), and its English, of a Problem. A
 * value's code says what the option expected (english prefixes "expected
 * "); the others say the whole of it.
 *
 * @typedef {{ args: string[], value: boolean, text: function(Problem): string }} ProblemCode
 */

// A value the option does not take.

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
 * Not an absolute path: the datatypes directory and file.
 *
 * @type {string}
 */
export const ABSOLUTE_PATH = 'ABSOLUTE_PATH';

/**
 * Not a directory the service may make and mount for a collector: one under
 * /var, /tmp or /etc/prometheus-exporter (config.types' OWNED_ROOTS), the
 * datatype owned_directory.
 *
 * @type {string}
 */
export const OWNED_DIRECTORY = 'OWNED_DIRECTORY';

/**
 * Not a regular expression regexp() compiles: the datatype regex.
 *
 * @type {string}
 */
export const REGEX = 'REGEX';

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
 * A crypt hash of more rounds than `max`, which a scrape would compute to
 * check the password: the datatype crypt.
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

// Options that go together (config.together).

/**
 * auth_user without auth_password.
 *
 * @type {string}
 */
export const AUTH_NEEDS_PASSWORD = 'AUTH_NEEDS_PASSWORD';

/**
 * auth_password without auth_user.
 *
 * @type {string}
 */
export const AUTH_NEEDS_USER = 'AUTH_NEEDS_USER';

/**
 * Basic auth without cert and key: Basic sends the password in the clear.
 *
 * @type {string}
 */
export const AUTH_NEEDS_TLS = 'AUTH_NEEDS_TLS';

/**
 * Every code, with what it takes and says: the closed set of what the
 * exporter finds wrong with an option's value.
 *
 * @type {Object<string, ProblemCode>}
 */
export const CODES = {
	[BOOLEAN]: { args: [], value: true, text: () => 'a boolean' },
	[INTEGER]: { args: [], value: true, text: () => 'an integer' },
	[SINGLE]: { args: [], value: true, text: () => 'a single value' },
	[RANGE]: { args: [ 'min', 'max' ], value: true, text: (p) => `an integer from ${p.min} to ${p.max}` },
	[UINTEGER]: { args: [], value: true, text: () => 'an integer of 0 or more' },
	[ABSOLUTE_PATH]: { args: [], value: true, text: () => 'an absolute path' },
	[OWNED_DIRECTORY]: {
		args: [], value: true,
		text: () => 'a directory under /var, /tmp or /etc/prometheus-exporter, which the service makes and mounts',
	},
	[REGEX]: { args: [], value: true, text: () => 'a regular expression' },
	[USERNAME]: { args: [], value: true, text: () => 'a user of 1 to 64 characters, without ":", spaces or control characters' },
	[CRYPT]: { args: [], value: true, text: () => 'a crypt hash: $1$ (uhttpd -m), $5$ or $6$' },
	[CRYPT_ROUNDS]: {
		args: [ 'max' ], value: true,
		text: (p) => `a hash of at most ${p.max} rounds, which a scrape computes to check the password ` +
			'(hash_password makes one of 1000; one without rounds= has 5000)',
	},
	[INTERFACE]: { args: [], value: true, text: () => 'an interface name or *' },
	[AUTH_NEEDS_PASSWORD]: { args: [], value: false, text: () => 'basic auth needs the hash of a password along with auth_user' },
	[AUTH_NEEDS_USER]: { args: [], value: false, text: () => 'basic auth needs a user along with auth_password' },
	[AUTH_NEEDS_TLS]: {
		args: [], value: false,
		text: () => 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
	},
};

/**
 * A Problem of `code`, with its arguments and, for a code of a value, the
 * value; it dies of a code CODES does not have, or of an argument the code
 * does not take, which only the core's own code can give it.
 *
 * @param {string} code one of CODES.
 * @param {?Object} args the code's arguments (ProblemCode's args), and
 *   `value`, of a value's code, unless the option is a secret.
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
 * What a value's code expected, without what it got: 'an integer from 1 to
 * 30'. The datatypes say it as what they take.
 *
 * @param {Problem} p the problem.
 * @returns {string} what the option expected.
 */
export function expected(p) {
	return CODES[p.code].text(p);
};

/**
 * A problem in English, without the option's name: 'expected an integer
 * from 1 to 30, got 0', or the whole of one of options that go together.
 * The value is spelt as JSON: a string in quotes.
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
 * A problem in English, after the option's name: what a CONFIG_INVALID's
 * details say.
 *
 * @param {string} name the option's name.
 * @param {Problem} p the problem.
 * @returns {string} 'name: ' and its English.
 */
export function message(name, p) {
	return `${name}: ${english(p)}`;
};
