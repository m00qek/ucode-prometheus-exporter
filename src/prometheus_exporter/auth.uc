/**
 * Basic auth of /metrics, which the main section's auth_user and auth_password
 * (a crypt hash) turn on, over HTTPS only (see config.together).
 *
 * The init script writes uhttpd's config file (FILE): one line, PATH:user:hash,
 * mode 0600, in a directory of mode 0700. uhttpd reads it with -c, and -r
 * names its realm; the jail mounts it read-only. OpenWrt 25.12's uhttpd checks
 * a realm for files and CGI only, not for a handler's prefix (its fix is
 * newer), so the handler checks it too: it reads the same file when it starts,
 * and answers 401 to a request without the user and password, before any
 * scrape. A file that is there but not one line of a user and a hash denies
 * every request, and so does a file that is not there while the config sets
 * auth_user (prometheus_exporter.app's load_auth). Neither the password nor the hash is ever logged.
 *
 * Computing the hash is what a check costs, and on a router's CPU it costs
 * much (see docs/explanation/performance.md): so the handler remembers the
 * last header it let in, in the instance's state (prometheus_exporter.state),
 * as a digest bound to the user and hash it was checked against (CACHE). A
 * request with that very header is let in on the digest alone; any other pays
 * the full check.
 *
 * @module prometheus_exporter_auth
 */

'use strict';

import { sha256 } from 'digest';
import * as crypt from 'prometheus_exporter.crypt';
import * as hashes from 'prometheus_exporter.hashes';
import * as state from 'prometheus_exporter.state';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { GROUP } from 'prometheus_exporter.privileges';

/**
 * Basic auth as the config and uhttpd's file set it: the user, and the crypt
 * hash of the password.
 *
 * @typedef {{ user: string, hash: string }} BasicAuth
 */

/**
 * The user and password of an Authorization header, as credentials() reads
 * them.
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

// Whether a user is one basic auth takes, the most rounds a hash of
// auth_password may take, and whether a hash is one basic auth takes
// (prometheus_exporter.hashes, which the config's datatypes take them from).
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
 * Writes uhttpd's config file for `auth` ({ user, hash }) whole, mode 0640,
 * root's and the service's group's (privileges.GROUP), which uhttpd and the
 * handler run as in the jail, in DIR of mode 0700, and puts it in place by a
 * rename, so the jail of a running instance keeps the file it mounted; with
 * `auth` null, removes it. A Result of the path written, or of null. fs:
 * { stat, mkdir, chmod, chown, open, rename, unlink, error }, as the fs module
 * has them.
 *
 * @param {module:fs} fs the fs module, or an object of the functions named.
 * @param {?BasicAuth} auth basic auth, or null for none.
 * @returns {Result<?string>} FILE, or null when it removed it; or
 *   FILE_UNWRITABLE.
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
 * { user, hash } of uhttpd's config file, or null when it is not one line of a
 * user and a hash for PATH.
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
 * The name of basic auth's cache in the state: one entry, the digest of the
 * last header let in.
 *
 * @type {string}
 */
export const CACHE = 'auth';

/**
 * The digest the cache keeps of an Authorization header let in by `auth`
 * ({ user, hash }): SHA-256 of the header, the user and the hash, each ended
 * by a NUL, which none of them holds. Bound to the user and hash, an entry
 * lets nothing in once either changes. It is no secret beyond the hash's: it
 * lives in a directory as closed as uhttpd's file, and finding a header that
 * gives it is guessing the password, as with the hash.
 *
 * @param {BasicAuth} auth the basic auth it let the header in by.
 * @param {string} value the header's value.
 * @returns {string} the digest, as hex.
 */
export function digest(auth, value) {
	return sha256(`${value}\0${auth.user}\0${auth.hash}\0`);
};

/**
 * Whether an Authorization header carries the user and password of `auth`
 * ({ user, hash }). The hash is computed for any user, so a wrong user takes
 * as long as a wrong password. With `instance`, the instance's state (state.open),
 * the header the cache holds, compared in constant time, is let in without
 * computing the hash; one that is let in otherwise replaces it.
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
 * Why `password` cannot be hashed, or null: a string of 1 to PASSWORD_MAX
 * bytes, without control characters.
 *
 * @param {*} password what is to be hashed: anything a caller gave (a ubus
 *   argument, a line read), which this checks.
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
 * The rounds of the hashes hash_password makes: musl's least, as the handler
 * computes the hash in ucode at each scrape; see docs/explanation/performance.md.
 *
 * @type {int}
 */
export const HASH_ROUNDS = 1000;

/**
 * A Result of a new SHA-512-crypt hash of `password`, salted with random(n),
 * which gives n random bytes.
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
