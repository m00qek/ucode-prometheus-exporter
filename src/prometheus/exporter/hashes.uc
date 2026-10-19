/**
 * What basic auth takes, checked without computing a hash: a user, and crypt(3) hash formats.
 *
 * @module prometheus_exporter_hashes
 */

'use strict';

/**
 * The rounds of a $5$ or $6$ hash that names none.
 *
 * @type {int}
 */
export const ROUNDS_DEFAULT = 5000;

const FORMATS = { '1': [ 8, 22 ], '5': [ 16, 43 ], '6': [ 16, 86 ] };
const ALPHABET = /^[.\/0-9A-Za-z]*$/;
const ROUNDS = /^rounds=[1-9][0-9]*$/;

/**
 * Whether `value` is a hash of one of the formats.
 *
 * @param {*} value anything; only a string is a hash.
 * @returns {boolean} whether it is one.
 */
export function is_hash(value) {
	if (type(value) != 'string')
		return false;

	let parts = split(value, '$');
	let n = length(parts);
	let f = (n >= 4 && parts[0] == '') ? FORMATS[parts[1]] : null;

	if (f == null)
		return false;

	if (n == 5) {
		let r = parts[2];

		if (parts[1] == '1' || length(r) < 11 || length(r) > 14 || !match(r, ROUNDS))
			return false;
	} else if (n != 4) {
		return false;
	}

	let s = parts[n - 2], d = parts[n - 1];

	return length(s) <= f[0] && length(d) == f[1] && match(s + d, ALPHABET) != null;
};

/**
 * The rounds computing `hash` takes, or null when it is not of one of the formats.
 *
 * @param {*} hash anything; only a string is a hash.
 * @returns {?int} the rounds.
 */
export function rounds(hash) {
	if (!is_hash(hash))
		return null;

	let parts = split(hash, '$');

	if (parts[1] == '1')
		return 1000;

	return (substr(parts[2], 0, 7) == 'rounds=') ? int(substr(parts[2], 7)) : ROUNDS_DEFAULT;
};

/**
 * Whether `user` is a user basic auth takes: 1 to 64 bytes, no ':', space or control.
 *
 * @param {*} user anything; only a string is a user.
 * @returns {boolean} whether it is one.
 */
export function is_user(user) {
	return type(user) == 'string' && match(user, /^[^:[:space:][:cntrl:]]{1,64}$/) != null;
};

/**
 * The most rounds a hash of auth_password may take (see rounds).
 *
 * @type {int}
 */
export const AUTH_ROUNDS_MAX = 2000;

/**
 * Whether `value` is a hash basic auth takes: of at most AUTH_ROUNDS_MAX rounds.
 *
 * @param {*} value anything; only a string is a hash.
 * @returns {boolean} whether it is one.
 */
export function is_auth_hash(value) {
	let n = rounds(value);

	return n != null && n <= AUTH_ROUNDS_MAX;
};
