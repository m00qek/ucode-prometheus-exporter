/**
 * Basic auth of /metrics, over HTTPS only.
 *
 * @module prometheus_exporter_auth
 */

'use strict';

import { sha256 } from 'digest';
import * as crypt from 'prometheus.exporter.crypt';
import * as hashes from 'prometheus.exporter.hashes';
import * as state from 'prometheus.exporter.state';
import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import { GROUP } from 'prometheus.exporter.privileges';

/**
 * Basic auth as the config and uhttpd's file set it: the user, and the crypt hash of the password.
 *
 * @typedef {{ user: string, hash: string }} BasicAuth
 */

/**
 * The user and password of an Authorization header, as credentials() reads them.
 *
 * @typedef {{ user: string, password: string }} Credentials
 */

/**
 * The path basic auth guards: the handler's prefix.
 *
 * @type {string}
 */
export const PATH = '/metrics';

/**
 * The realm uhttpd (-r) and the handler's 401 name.
 *
 * @type {string}
 */
export const REALM = 'prometheus-exporter';

/**
 * The directory of uhttpd's config file: the state's RUN_DIR.
 *
 * @type {string}
 */
export const DIR = state.RUN_DIR;

/**
 * uhttpd's config file, which the init script writes.
 *
 * @type {string}
 */
export const FILE = `${DIR}/uhttpd.conf`;

/**
 * The longest password hash_password takes: the longest musl hashes.
 *
 * @type {int}
 */
export const PASSWORD_MAX = crypt.KEY_MAX;

export const is_user = hashes.is_user;
export const ROUNDS_MAX = hashes.AUTH_ROUNDS_MAX;
export const is_hash = hashes.is_auth_hash;

/**
 * uhttpd's config file for user and hash.
 *
 * @param {string} user the user.
 * @param {string} hash the hash.
 * @returns {string} its one line, PATH:user:hash, ended by a newline.
 */
export function conf(user, hash) {
	return `${PATH}:${user}:${hash}\n`;
};

/**
 * Writes uhttpd's config file for `auth` whole, or removes it for null.
 *
 * @param {module:fs} fs the fs module, or a test's object of its functions.
 * @param {?BasicAuth} auth basic auth, or null for none.
 * @returns {Result<?string>} FILE, or null when it removed it; or FILE_UNWRITABLE.
 */
export function write_conf(fs, auth) {
	let failed = (what) => Result.err(errors.FILE_UNWRITABLE, `cannot ${what} ${FILE}: ${fs.error()}`);

	if (auth == null)
		return (fs.stat(FILE) == null || fs.unlink(FILE)) ? Result.ok(null) : failed('remove');

	let tmp = `${FILE}.new`;

	if ((fs.stat(DIR) == null && !fs.mkdir(DIR, 0o700)) || !fs.chmod(DIR, 0o700))
		return failed('make the directory of');

	fs.unlink(tmp);

	let f = fs.open(tmp, 'w', 0o600);
	let ok = f != null && f.write(conf(auth.user, auth.hash)) != null;

	ok = (f?.close() ?? false) && ok && fs.chown(tmp, 0, GROUP) && fs.chmod(tmp, 0o640) && fs.rename(tmp, FILE);

	if (!ok) {
		let res = failed('write');

		fs.unlink(tmp);
		return res;
	}

	return Result.ok(FILE);
};

/**
 * { user, hash } of uhttpd's config file, or null when it is not one.
 *
 * @param {?string} text the file's text.
 * @returns {?BasicAuth} basic auth, or null.
 */
export function parse_conf(text) {
	let m = (type(text) == 'string') ? match(text, /^([^:\n]*):([^:\n]*):([^:\n]*)\n?$/) : null;

	if (!m || m[1] != PATH || !is_user(m[2]) || !is_hash(m[3]))
		return null;

	return { user: m[2], hash: m[3] };
};

/**
 * { user, password } of an Authorization header of the Basic scheme, or null.
 *
 * @param {?string} value the header's value.
 * @returns {?Credentials} the user and password, or null.
 */
export function credentials(value) {
	let m = (type(value) == 'string') ? match(value, /^[Bb][Aa][Ss][Ii][Cc][ \t]+([A-Za-z0-9+\/]+={0,2})[ \t]*$/) : null;
	let text = m ? b64dec(m[1]) : null;
	let i = (type(text) == 'string') ? index(text, ':') : -1;

	if (i < 0)
		return null;

	return { user: substr(text, 0, i), password: substr(text, i + 1) };
};

/**
 * The name of basic auth's cache in the state: one entry, the digest of the last header let in.
 *
 * @type {string}
 */
export const CACHE = 'auth';

/**
 * The digest the cache keeps of an Authorization header that `auth` let in.
 *
 * @param {BasicAuth} auth the basic auth it let the header in by.
 * @param {string} value the header's value.
 * @returns {string} the digest, as hex.
 */
export function digest(auth, value) {
	return sha256(`${value}\0${auth.user}\0${auth.hash}\0`);
};

/**
 * Whether an Authorization header carries the user and password of `auth` ({ user, hash }).
 *
 * @param {BasicAuth} auth basic auth.
 * @param {?string} value the Authorization header's value, or null.
 * @param {?State} instance the instance's state, for the cache; null for none.
 * @returns {boolean} whether the request is let in.
 */
export function allowed(auth, value, instance) {
	let d = (instance != null && type(value) == 'string') ? digest(auth, value) : null;

	if (d != null && crypt.same(instance.read(CACHE), d))
		return true;

	let c = credentials(value);

	if (c == null)
		return false;

	let password = crypt.verify(c.password, auth.hash);
	let ok = crypt.same(c.user, auth.user) && password;

	if (ok && d != null)
		instance.write(CACHE, d);

	return ok;
};

/**
 * Why `password` cannot be hashed, or null.
 *
 * @param {*} password anything a caller gave: a ubus argument, a line read.
 * @returns {?string} why it cannot be, or null.
 */
export function password_problem(password) {
	if (type(password) != 'string' || password == '')
		return 'expected a password';
	if (length(password) > PASSWORD_MAX)
		return `expected a password of at most ${PASSWORD_MAX} bytes`;
	if (match(password, /[[:cntrl:]]/))
		return 'expected a password without control characters';

	return null;
};

/**
 * The rounds of the hashes hash_password makes: musl's least.
 *
 * @type {int}
 */
export const HASH_ROUNDS = 1000;

/**
 * A Result of a new SHA-512-crypt hash of `password`.
 *
 * @param {*} password the password; anything but a string fails.
 * @param {function(int): ?string} random n random bytes.
 * @returns {Result<string>} the hash, or CONFIG_INVALID.
 */
export function hash_password(password, random) {
	let problem = password_problem(password);

	if (problem)
		return Result.err(errors.CONFIG_INVALID, problem);

	let bytes = random(crypt.SALT_BYTES);

	if (type(bytes) != 'string' || length(bytes) != crypt.SALT_BYTES)
		return Result.err(errors.CONFIG_INVALID, 'no random bytes for a salt');

	return Result.ok(crypt.hash(password, bytes, HASH_ROUNDS));
};
