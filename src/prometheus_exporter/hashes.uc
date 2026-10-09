/**
 * What basic auth takes, checked without computing a hash: a user, and the
 * crypt(3) hash formats of its password, which prometheus_exporter.crypt
 * computes and prometheus_exporter.auth checks a request by. The config's
 * datatypes take them from here (prometheus_exporter.config.types), as the
 * handler, which reads the config at every scrape, holds this module and not
 * those two, unless the config sets basic auth: uhttpd holds what its
 * program compiled for as long as it runs. crypt and auth export what is here
 * under their own names.
 *
 * A hash is $<id>$[rounds=<n>$]<salt>$<digest>: a salt of up to 8 characters
 * for $1$, up to 16 for $5$ and $6$, which may name their rounds (1000 to
 * 9999999; 5000 when they do not).
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

// The formats, as a whole hash: what the config takes. Rounds are written as
// musl writes them back (no leading zero, in range), or no password would
// match. Not DES's 13 characters, which a plain password could be (uhttpd
// compares a value without a leading $ as plain text), nor bcrypt, which
// ucode cannot compute in the time of a scrape.
//
// Each is checked as its parts between the $s, their lengths counted and
// their characters matched without a count: musl compiles a count, as
// [...]{86}, into a copy of what it counts for each, and the three formats
// as one regex each held 350 kB of the handler's memory, for as long as
// uhttpd runs. By the format's id: the salt's most characters, and the
// digest's.
const FORMATS = { '1': [ 8, 22 ], '5': [ 16, 43 ], '6': [ 16, 86 ] };
const ALPHABET = /^[.\/0-9A-Za-z]*$/;
// rounds= and 4 to 7 digits, the first not 0.
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

	// '', the id, rounds= when it names them, the salt and the digest.
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
 * The rounds computing `hash` takes, or null when it is not of one of the
 * formats: MD5-crypt's are 1000, always; SHA-crypt's those it names, or
 * ROUNDS_DEFAULT.
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
 * Whether `user` is a user basic auth takes: 1 to 64 bytes, without ':', which
 * ends the user in the credentials and in uhttpd's file, white space or
 * control characters.
 *
 * @param {*} user anything; only a string is a user.
 * @returns {boolean} whether it is one.
 */
export function is_user(user) {
	return type(user) == 'string' && match(user, /^[^:[:space:][:cntrl:]]{1,64}$/) != null;
};

/**
 * The most rounds a hash of auth_password may take (see rounds). The
 * handler computes the hash in ucode to check a password, and a $5$ or $6$
 * hash may name up to 9,999,999 rounds: at the 125 us a round of SHA-512-crypt
 * takes a MIPS 24Kc of 500 MIPS (an MT7621-class router; make bench-qemu),
 * that is 20 minutes a scrape. At 2000 rounds the check takes it 0.26 s (0.21 s
 * for SHA-256-crypt), the R3S 37 ms, x86_64 8 ms: a few hundred milliseconds
 * at most on a slow router, twice hash_password's, which the cache then spares
 * all but the first scrape. MD5-crypt is always 1000 (63 ms there). A hash
 * that names no rounds is of 5000 (0.63 s there), and so is refused: name
 * rounds=1000, as hash_password does.
 *
 * @type {int}
 */
export const AUTH_ROUNDS_MAX = 2000;

/**
 * Whether `value` is a hash basic auth takes: of the formats, and of at most
 * AUTH_ROUNDS_MAX rounds.
 *
 * @param {*} value anything; only a string is a hash.
 * @returns {boolean} whether it is one.
 */
export function is_auth_hash(value) {
	let n = rounds(value);

	return n != null && n <= AUTH_ROUNDS_MAX;
};
