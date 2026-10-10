/**
 * The crypt(3) hashes of basic auth's password, bit for bit as musl's.
 *
 * @module prometheus_exporter_crypt
 */

'use strict';

import { md5, sha256, sha512 } from 'digest';
import * as hashes from 'prometheus.exporter.hashes';

/** The crypt alphabet: 64 characters, each 6 bits of a digest or a salt. */
export const ITOA64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

export const ROUNDS_DEFAULT = hashes.ROUNDS_DEFAULT;

/** The fewest rounds a $5$ or $6$ hash may name. */
export const ROUNDS_MIN = 1000;

/** The most rounds a $5$ or $6$ hash may name. */
export const ROUNDS_MAX = 9999999;

/** The longest password musl hashes with $5$ and $6$, in bytes. */
export const KEY_MAX = 256;

function to64(v, n) {
	let out = '';

	for (let i = 0; i < n; i++) {
		out += substr(ITOA64, v & 0x3f, 1);
		v >>= 6;
	}

	return out;
}

function triple(d, a, b, c, n) {
	return to64((ord(d, a) << 16) | (ord(d, b) << 8) | ord(d, c), n);
}

function repeat(s, n) {
	let out = '';

	for (let i = 0; i < n; i++)
		out += s;

	return out;
}

function stretch(s, n) {
	let out = '';

	for (; n >= length(s); n -= length(s))
		out += s;

	return out + substr(s, 0, n);
}

/**
 * MD5-crypt of `key` with `salt` (up to 8 characters), as FreeBSD's md5crypt.
 *
 * @param {string} key
 * @param {string} salt
 * @returns {string}
 */
export function md5_crypt(key, salt) {
	let h = (s) => hexdec(md5(s));
	let alt = h(key + salt + key);
	let ctx = key + '$1$' + salt + stretch(alt, length(key));

	for (let i = length(key); i > 0; i >>= 1)
		ctx += (i & 1) ? '\0' : substr(key, 0, 1);

	let fin = h(ctx);

	for (let i = 0; i < 1000; i++) {
		let c = (i & 1) ? key : fin;

		if (i % 3)
			c += salt;
		if (i % 7)
			c += key;
		fin = h(c + ((i & 1) ? fin : key));
	}

	return '$1$' + salt + '$' +
		triple(fin, 0, 6, 12, 4) + triple(fin, 1, 7, 13, 4) + triple(fin, 2, 8, 14, 4) +
		triple(fin, 3, 9, 15, 4) + triple(fin, 4, 10, 5, 4) + to64(ord(fin, 11), 2);
};

const SHA256_ORDER = [
	[ 0, 10, 20 ], [ 21, 1, 11 ], [ 12, 22, 2 ], [ 3, 13, 23 ], [ 24, 4, 14 ],
	[ 15, 25, 5 ], [ 6, 16, 26 ], [ 27, 7, 17 ], [ 18, 28, 8 ], [ 9, 19, 29 ],
];

const SHA512_ORDER = [
	[ 0, 21, 42 ], [ 22, 43, 1 ], [ 44, 2, 23 ], [ 3, 24, 45 ], [ 25, 46, 4 ],
	[ 47, 5, 26 ], [ 6, 27, 48 ], [ 28, 49, 7 ], [ 50, 8, 29 ], [ 9, 30, 51 ],
	[ 31, 52, 10 ], [ 53, 11, 32 ], [ 12, 33, 54 ], [ 34, 55, 13 ], [ 56, 14, 35 ],
	[ 15, 36, 57 ], [ 37, 58, 16 ], [ 59, 17, 38 ], [ 18, 39, 60 ], [ 40, 61, 19 ],
	[ 62, 20, 41 ],
];

/**
 * SHA-crypt of `key`: id '5' (SHA-256) or '6' (SHA-512).
 *
 * @param {string} id
 * @param {string} key
 * @param {string} salt
 * @param {?int} rounds
 * @returns {string}
 */
export function sha_crypt(id, key, salt, rounds) {
	let sha = (id == '5') ? sha256 : sha512;
	let h = (s) => hexdec(sha(s));
	let klen = length(key);
	let b = h(key + salt + key);
	let a = key + salt + stretch(b, klen);

	for (let i = klen; i > 0; i >>= 1)
		a += (i & 1) ? b : key;

	a = h(a);

	let p = stretch(h(repeat(key, klen)), klen);
	let s = stretch(h(repeat(salt, 16 + ord(a, 0))), length(salt));
	let c = a;
	let n = rounds ?? ROUNDS_DEFAULT;

	for (let i = 0; i < n; i++) {
		let x = (i & 1) ? p : c;

		if (i % 3)
			x += s;
		if (i % 7)
			x += p;
		c = h(x + ((i & 1) ? c : p));
	}

	let out = '';

	for (let t in (id == '5' ? SHA256_ORDER : SHA512_ORDER))
		out += triple(c, t[0], t[1], t[2], 4);

	out += (id == '5') ? to64((ord(c, 31) << 8) | ord(c, 30), 3) : to64(ord(c, 63), 2);

	return `$${id}$` + (rounds != null ? `rounds=${rounds}$` : '') + salt + '$' + out;
};

export const is_hash = hashes.is_hash;
export const rounds = hashes.rounds;

/**
 * crypt(key, hash): the hash of `key` with the salt and rounds of `hash`, or null.
 *
 * @param {string} key
 * @param {string} hash
 * @returns {?string}
 */
export function crypt(key, hash) {
	if (type(key) != 'string' || index(key, '\0') >= 0 || !is_hash(hash))
		return null;

	let parts = split(hash, '$');
	let id = parts[1];

	if (id == '1')
		return md5_crypt(key, parts[2]);

	if (length(key) > KEY_MAX)
		return null;

	if (substr(parts[2], 0, 7) == 'rounds=')
		return sha_crypt(id, key, parts[3], int(substr(parts[2], 7)));

	return sha_crypt(id, key, parts[2], null);
};

/**
 * Whether a and b are the same string, in a time that depends on their lengths alone.
 *
 * @param {*} a
 * @param {*} b
 * @returns {boolean}
 */
export function same(a, b) {
	if (type(a) != 'string' || type(b) != 'string' || length(a) != length(b))
		return false;

	let diff = 0;

	for (let i = 0; i < length(a); i++)
		diff |= ord(a, i) ^ ord(b, i);

	return diff == 0;
};

/**
 * Whether `key` is the password of `hash`.
 *
 * @param {string} key
 * @param {string} hash
 * @returns {boolean}
 */
export function verify(key, hash) {
	let h = crypt(key, hash);

	return h != null && same(h, hash);
};

/** The bytes of randomness a salt takes: 16 characters of 6 bits. */
export const SALT_BYTES = 12;

/**
 * A new SHA-512-crypt hash of `key`, its salt made of `bytes`.
 *
 * @param {string} key
 * @param {string} bytes
 * @param {?int} rounds
 * @returns {string}
 */
export function hash(key, bytes, rounds) {
	let salt = '';

	for (let i = 0; i < SALT_BYTES; i += 3)
		salt += triple(bytes, i, i + 1, i + 2, 4);

	return sha_crypt('6', key, salt, rounds);
};
