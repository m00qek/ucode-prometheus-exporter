'use strict';

// Basic auth of /metrics, which the main section's auth_user and auth_password
// (a crypt hash) turn on, over HTTPS only (see config.together).
//
// The init script writes uhttpd's config file (FILE): one line, PATH:user:hash,
// mode 0600, in a directory of mode 0700. uhttpd reads it with -c, and -r
// names its realm; the jail mounts it read-only. OpenWrt 25.12's uhttpd checks
// a realm for files and CGI only, not for a handler's prefix (its fix is
// newer), so the handler checks it too: it reads the same file when it starts,
// and answers 401 to a request without the user and password, before any
// scrape. A file that is there but not one line of a user and a hash denies
// every request. Neither the password nor the hash is ever logged.
//
// Computing the hash is what a check costs, and on a router's CPU it costs
// much (see docs/explanation/performance.md): so the handler remembers the
// last header it let in, in the instance's state (prometheus_exporter.state),
// as a digest bound to the user and hash it was checked against (CACHE). A
// request with that very header is let in on the digest alone; any other pays
// the full check.

import { sha256 } from 'digest';
import * as crypt from 'prometheus_exporter.crypt';
import * as state from 'prometheus_exporter.state';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const PATH = '/metrics';
export const REALM = 'prometheus-exporter';
export const DIR = state.RUN_DIR;
export const FILE = `${DIR}/uhttpd.conf`;

// The longest password hash_password takes: the longest musl hashes.
export const PASSWORD_MAX = crypt.KEY_MAX;

// Whether `s` is a user basic auth takes: 1 to 64 bytes, without ':', which
// ends the user in the credentials and in uhttpd's file, white space or
// control characters.
export function is_user(s) {
	return type(s) == 'string' && match(s, /^[^:[:space:][:cntrl:]]{1,64}$/) != null;
};

// The most rounds a hash of auth_password may take (see crypt.rounds). The
// handler computes the hash in ucode to check a password, and a $5$ or $6$
// hash may name up to 9,999,999 rounds: at the 125 us a round of SHA-512-crypt
// takes a MIPS 24Kc of 500 MIPS (an MT7621-class router; make bench-qemu),
// that is 20 minutes a scrape. At 2000 rounds the check takes it 0.26 s (0.21 s
// for SHA-256-crypt), the R3S 37 ms, x86_64 8 ms: a few hundred milliseconds
// at most on a slow router, twice hash_password's, which the cache then spares
// all but the first scrape. MD5-crypt is always 1000 (63 ms there). A hash
// that names no rounds is of 5000 (0.63 s there), and so is refused: name
// rounds=1000, as hash_password does.
export const ROUNDS_MAX = 2000;

// Whether `s` is a hash basic auth takes: of crypt's formats, and of at most
// ROUNDS_MAX rounds.
export function is_hash(s) {
	let n = crypt.rounds(s);

	return n != null && n <= ROUNDS_MAX;
};

// uhttpd's config file for user and hash.
export function conf(user, hash) {
	return `${PATH}:${user}:${hash}\n`;
};

// Writes uhttpd's config file for `a` ({ user, hash }) whole, mode 0600 in DIR
// of mode 0700, and puts it in place by a rename, so the jail of a running
// instance keeps the file it mounted; with `a` null, removes it. A Result of
// the path written, or of null. fs: { stat, mkdir, chmod, open, rename,
// unlink, error }, as the fs module has them.
export function write_conf(fs, a) {
	let failed = (what) => Result.err(errors.FILE_UNWRITABLE, `cannot ${what} ${FILE}: ${fs.error()}`);

	if (a == null)
		return (fs.stat(FILE) == null || fs.unlink(FILE)) ? Result.ok(null) : failed('remove');

	let tmp = `${FILE}.new`;

	if ((fs.stat(DIR) == null && !fs.mkdir(DIR, 0o700)) || !fs.chmod(DIR, 0o700))
		return failed('make the directory of');

	fs.unlink(tmp);

	let f = fs.open(tmp, 'w', 0o600);
	let ok = f != null && f.write(conf(a.user, a.hash)) != null;

	ok = (f?.close() ?? false) && ok && fs.chmod(tmp, 0o600) && fs.rename(tmp, FILE);

	if (!ok) {
		let res = failed('write');

		fs.unlink(tmp);
		return res;
	}

	return Result.ok(FILE);
};

// { user, hash } of uhttpd's config file, or null when it is not one line of a
// user and a hash for PATH.
export function parse_conf(text) {
	let m = (type(text) == 'string') ? match(text, /^([^:\n]*):([^:\n]*):([^:\n]*)\n?$/) : null;

	if (!m || m[1] != PATH || !is_user(m[2]) || !is_hash(m[3]))
		return null;

	return { user: m[2], hash: m[3] };
};

// { user, password } of an Authorization header of the Basic scheme, or null.
export function credentials(value) {
	let m = (type(value) == 'string') ? match(value, /^[Bb][Aa][Ss][Ii][Cc][ \t]+([A-Za-z0-9+\/]+={0,2})[ \t]*$/) : null;
	let text = m ? b64dec(m[1]) : null;
	let i = (type(text) == 'string') ? index(text, ':') : -1;

	if (i < 0)
		return null;

	return { user: substr(text, 0, i), password: substr(text, i + 1) };
};

// The name of basic auth's cache in the state: one entry, the digest of the
// last header let in.
export const CACHE = 'auth';

// The digest the cache keeps of an Authorization header let in by `a`
// ({ user, hash }): SHA-256 of the header, the user and the hash, each ended
// by a NUL, which none of them holds. Bound to the user and hash, an entry
// lets nothing in once either changes. It is no secret beyond the hash's: it
// lives in a directory as closed as uhttpd's file, and finding a header that
// gives it is guessing the password, as with the hash.
export function digest(a, value) {
	return sha256(`${value}\0${a.user}\0${a.hash}\0`);
};

// Whether an Authorization header carries the user and password of `a`
// ({ user, hash }). The hash is computed for any user, so a wrong user takes
// as long as a wrong password. With `st`, the instance's state (state.open),
// the header the cache holds, compared in constant time, is let in without
// computing the hash; one that is let in otherwise replaces it.
export function allowed(a, value, st) {
	let d = (st != null && type(value) == 'string') ? digest(a, value) : null;

	if (d != null && crypt.same(st.read(CACHE), d))
		return true;

	let c = credentials(value);

	if (c == null)
		return false;

	let password = crypt.verify(c.password, a.hash);
	let ok = crypt.same(c.user, a.user) && password;

	if (ok && d != null)
		st.write(CACHE, d);

	return ok;
};

// Why `password` cannot be hashed, or null: a string of 1 to PASSWORD_MAX
// bytes, without control characters.
export function password_problem(password) {
	if (type(password) != 'string' || password == '')
		return 'expected a password';
	if (length(password) > PASSWORD_MAX)
		return `expected a password of at most ${PASSWORD_MAX} bytes`;
	if (match(password, /[[:cntrl:]]/))
		return 'expected a password without control characters';

	return null;
};

// The rounds of the hashes hash_password makes: musl's least, as the handler
// computes the hash in ucode at each scrape; see docs/explanation/performance.md.
export const HASH_ROUNDS = 1000;

// A Result of a new SHA-512-crypt hash of `password`, salted with random(n),
// which gives n random bytes.
export function hash_password(password, random) {
	let problem = password_problem(password);

	if (problem)
		return Result.err(errors.CONFIG_INVALID, problem);

	let bytes = random(crypt.SALT_BYTES);

	if (type(bytes) != 'string' || length(bytes) != crypt.SALT_BYTES)
		return Result.err(errors.CONFIG_INVALID, 'no random bytes for a salt');

	return Result.ok(crypt.hash(password, bytes, HASH_ROUNDS));
};
