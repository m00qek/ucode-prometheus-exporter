'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as auth from 'prometheus_exporter.auth';
import * as crypt from 'prometheus_exporter.crypt';

// `uhttpd -m secret`, on OpenWrt 25.12.
const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
const SHA = crypt.sha_crypt('6', 'secret', 'abcdefghijklmnop', 1000);
const A = { user: 'prom', hash: HASH };

function basic(text) {
	return 'Basic ' + b64enc(text);
}

const USER = gen.string({ min_len: 1, max_len: 64, charset: 'abcXYZ019._-@é' });
const PASSWORD = gen.string({ min_len: 1, max_len: 40, charset: 'abcXYZ019 !:$%&/\\"\'' });

describe('auth.conf and auth.parse_conf', () => {
	it('writes the line uhttpd reads for /metrics: path, user and hash', () => {
		assert.match('/metrics:prom:' + HASH + '\n', auth.conf('prom', HASH));
	});

	prop('reads back what it writes', gen.tuple(USER, gen.elements(HASH, SHA)), (t) => {
		if (auth.is_user(t[0]))
			assert.match({ user: t[0], hash: t[1] }, auth.parse_conf(auth.conf(t[0], t[1])));
	});

	it('reads nothing but one line of a user and a hash for /metrics', () => {
		assert.match([ null, null, null, null, null, null, null ], map([
			'',
			null,
			'/other:prom:' + HASH + '\n',
			'/metrics:prom:secret\n',
			'/metrics::' + HASH + '\n',
			'/metrics:prom:' + HASH + '\n/metrics:other:' + HASH + '\n',
			'/metrics:pr om:' + HASH + '\n',
		], auth.parse_conf));
	});
});

// A filesystem of `files` ({ path: { data, mode } }) and `dirs` ({ path: mode }),
// which logs each call; `broken` names the calls that fail.
function filesystem(files, dirs, broken) {
	let log = [];
	let fails = (name) => (name in (broken ?? []));
	let fs = {
		log, files, dirs,
		error: () => 'Permission denied',
		stat: (p) => (p in keys(files) || p in keys(dirs)) ? { type: (p in keys(dirs)) ? 'directory' : 'file' } : null,
		mkdir: function(p, mode) { push(log, `mkdir ${p} ${sprintf('%o', mode)}`); if (fails('mkdir')) return null; dirs[p] = mode; return true; },
		chmod: function(p, mode) {
			push(log, `chmod ${p} ${sprintf('%o', mode)}`);
			if (fails('chmod')) return null;
			if (p in keys(dirs)) dirs[p] = mode; else files[p].mode = mode;
			return true;
		},
		unlink: function(p) { push(log, `unlink ${p}`); if (fails('unlink') || !(p in keys(files))) return null; delete files[p]; return true; },
		rename: function(a, b) { push(log, `rename ${a} ${b}`); if (fails('rename')) return null; files[b] = files[a]; delete files[a]; return true; },
		open: function(p, how, mode) {
			push(log, `open ${p} ${how} ${sprintf('%o', mode)}`);
			if (fails('open')) return null;
			files[p] = { data: '', mode };
			return { write: (d) => { files[p].data += d; return length(d); }, close: () => true };
		},
	};

	return fs;
}

describe('auth.write_conf', () => {
	const A = { user: 'prom', hash: HASH };

	it('writes the file whole, 0600, in a directory of 0700, then renames it into place', () => {
		let fs = filesystem({}, {});
		let res = auth.write_conf(fs, A);

		assert.match([ true, auth.FILE ], [ res.ok, res.data ]);
		assert.match({ [auth.FILE]: { data: auth.conf('prom', HASH), mode: 0o600 } }, fs.files);
		assert.match({ [auth.DIR]: 0o700 }, fs.dirs);
		assert.match([
			`mkdir ${auth.DIR} 700`, `chmod ${auth.DIR} 700`, `unlink ${auth.FILE}.new`, `open ${auth.FILE}.new w 600`,
			`chmod ${auth.FILE}.new 600`, `rename ${auth.FILE}.new ${auth.FILE}`,
		], fs.log);
	});

	it('closes a directory there already to its owner, and replaces the file', () => {
		let fs = filesystem({ [auth.FILE]: { data: 'old', mode: 0o644 } }, { [auth.DIR]: 0o755 });

		assert.match(true, auth.write_conf(fs, A).ok);
		assert.match([ auth.conf('prom', HASH), 0o600, 0o700 ], [ fs.files[auth.FILE].data, fs.files[auth.FILE].mode, fs.dirs[auth.DIR] ]);
	});

	it('removes the file without basic auth, and is content when there is none', () => {
		let fs = filesystem({ [auth.FILE]: { data: 'old', mode: 0o600 } }, { [auth.DIR]: 0o700 });

		assert.match([ true, null, {} ], [ auth.write_conf(fs, null).ok, auth.write_conf(fs, null).data, fs.files ]);
	});

	it('says what it could not do, and leaves no half-written file', () => {
		let write = (broken) => {
			let fs = filesystem({}, {}, broken);
			let res = auth.write_conf(fs, A);
			return [ `${res.error}: ${res.details}`, keys(fs.files) ];
		};

		assert.match([
			[ `FILE_UNWRITABLE: cannot make the directory of ${auth.FILE}: Permission denied`, [] ],
			[ `FILE_UNWRITABLE: cannot write ${auth.FILE}: Permission denied`, [] ],
			[ `FILE_UNWRITABLE: cannot write ${auth.FILE}: Permission denied`, [] ],
		], [ write([ 'mkdir' ]), write([ 'open' ]), write([ 'rename' ]) ]);
	});

	it('never says the hash', () => {
		let fs = filesystem({}, {}, [ 'rename' ]);

		assert.match(-1, index(auth.write_conf(fs, A).details, HASH));
	});
});

describe('auth.is_user', () => {
	it('takes 1 to 64 bytes without ":", white space or control characters', () => {
		assert.match([ true, true, false, false, false, false, false, false ],
			map([ 'prometheus', 'vm-agent.1@lab', '', 'a:b', 'a b', 'a\tb', 'a\nb', sprintf('%065d', 0) ], auth.is_user));
	});

	prop('refuses any user with a ":"', gen.tuple(USER, USER), (t) => {
		assert.match(false, auth.is_user(t[0] + ':' + t[1]));
	});
});

describe('auth.credentials', () => {
	it('reads the user and password of a Basic header, the password up to its end', () => {
		assert.match([
			{ user: 'prom', password: 'secret' },
			{ user: 'prom', password: 'a:b' },
			{ user: '', password: '' },
			{ user: 'prom', password: 'secret' },
		], [
			auth.credentials(basic('prom:secret')),
			auth.credentials(basic('prom:a:b')),
			auth.credentials(basic(':')),
			auth.credentials('basic   ' + b64enc('prom:secret') + ' '),
		]);
	});

	it('reads nothing of another scheme, of bad base64 or without a ":"', () => {
		assert.match([ null, null, null, null, null ], map([
			'Bearer abc', 'Basic !!!!', 'Basic ' + b64enc('prom'), null, 'Basic',
		], auth.credentials));
	});

	prop('reads back any user and password', gen.tuple(USER, PASSWORD), (t) => {
		if (auth.is_user(t[0]))
			assert.match({ user: t[0], password: t[1] }, auth.credentials(basic(t[0] + ':' + t[1])));
	});
});

describe('auth.allowed', () => {
	it('lets in the user with the password of the hash', () => {
		assert.match([ true, true ], [ auth.allowed(A, basic('prom:secret')), auth.allowed({ user: 'prom', hash: SHA }, basic('prom:secret')) ]);
	});

	it('keeps out a wrong user, a wrong password, the hash as the password, and no credentials', () => {
		assert.match([ false, false, false, false, false ], [
			auth.allowed(A, basic('other:secret')),
			auth.allowed(A, basic('prom:wrong')),
			auth.allowed(A, basic('prom:' + HASH)),
			auth.allowed(A, null),
			auth.allowed(A, 'Basic'),
		]);
	});

	prop('lets in exactly the user and password of the hash', gen.tuple(PASSWORD, PASSWORD, gen.bool()), (t) => {
		let a = { user: 'prom', hash: crypt.md5_crypt(t[0], 'salt') };

		assert.match(t[0] == t[1] && t[2], auth.allowed(a, basic((t[2] ? 'prom' : 'other') + ':' + t[1])));
	}, { runs: 40 });
});

describe('auth.hash_password', () => {
	const random = (n) => substr('0123456789abcdef', 0, n);

	it('makes a SHA-512-crypt hash of HASH_ROUNDS, salted with the random bytes', () => {
		let res = auth.hash_password('secret', random);

		assert.match(true, res.ok);
		assert.match(true, match(res.data, /^\$6\$rounds=1000\$[.\/0-9A-Za-z]{16}\$[.\/0-9A-Za-z]{86}$/) != null);
		assert.match([ true, false ], [ crypt.verify('secret', res.data), crypt.verify('Secret', res.data) ]);
	});

	it('refuses an empty password, a long one, one with control characters, and no randomness', () => {
		let long = sprintf(`%0${auth.PASSWORD_MAX + 1}d`, 0);

		assert.match([
			'CONFIG_INVALID: expected a password',
			'CONFIG_INVALID: expected a password',
			`CONFIG_INVALID: expected a password of at most ${auth.PASSWORD_MAX} bytes`,
			'CONFIG_INVALID: expected a password without control characters',
			'CONFIG_INVALID: no random bytes for a salt',
		], map([
			auth.hash_password('', random),
			auth.hash_password(null, random),
			auth.hash_password(long, random),
			auth.hash_password('a\nb', random),
			auth.hash_password('secret', () => null),
		], (r) => `${r.error}: ${r.details}`));
	});

	prop('never says the password in what it refuses', gen.string({ min_len: 1, max_len: 12, charset: 'ab\x01\x7f' }), (p) => {
		let res = auth.hash_password(p, random);

		assert.match(true, res.ok || res.details == 'expected a password without control characters', p);
	});
});

function sha_hash(id, rounds) {
	return crypt.sha_crypt(id, 'secret', 'saltsalt', rounds);
}

describe('auth.is_hash', () => {
	it('takes hashes of up to ROUNDS_MAX rounds: MD5-crypt, hash_password\'s, and SHA-crypt at the cap', () => {
		assert.match([ true, true, true, true, true ], map([
			HASH, SHA, sha_hash('5', auth.ROUNDS_MAX), sha_hash('6', auth.ROUNDS_MAX), sha_hash('6', crypt.ROUNDS_MIN),
		], auth.is_hash));
	});

	it('refuses SHA-crypt of a round more than the cap, and of musl\'s most', () => {
		assert.match([ false, false, false ], map([
			sha_hash('5', auth.ROUNDS_MAX + 1),
			'$6$rounds=' + (auth.ROUNDS_MAX + 1) + '$saltsalt$' + substr(SHA, -86),
			'$6$rounds=' + crypt.ROUNDS_MAX + '$saltsalt$' + substr(SHA, -86),
		], auth.is_hash));
	});

	it('counts a hash that names no rounds at crypt\'s default', () => {
		assert.match(crypt.ROUNDS_DEFAULT <= auth.ROUNDS_MAX, auth.is_hash('$6$saltsalt$' + substr(SHA, -86)));
	});

	it('takes nothing crypt does not', () => {
		assert.match([ false, false ], [ auth.is_hash('hunter2'), auth.is_hash(null) ]);
	});

	it('takes the rounds hash_password makes', () => {
		assert.match(true, auth.HASH_ROUNDS <= auth.ROUNDS_MAX);
	});

	prop('takes a $5$ or $6$ hash exactly when its rounds are within the cap', gen.tuple(gen.elements('5', '6'),
		gen.oneof(gen.int(crypt.ROUNDS_MIN, crypt.ROUNDS_MAX), gen.int(auth.ROUNDS_MAX - 3, auth.ROUNDS_MAX + 3))), (t) => {
		let digest = (t[0] == '5') ? substr(sha_hash('5', 1000), -43) : substr(SHA, -86);
		let h = `$${t[0]}$rounds=${t[1]}$saltsalt$${digest}`;

		assert.match(t[1] <= auth.ROUNDS_MAX, auth.is_hash(h), h);
	});
});

describe('auth.parse_conf, over the cap', () => {
	it('reads no hash of more rounds than the cap, so the handler denies every request', () => {
		assert.match([ null, { user: 'prom', hash: sha_hash('6', auth.ROUNDS_MAX) } ], [
			auth.parse_conf(auth.conf('prom', sha_hash('6', auth.ROUNDS_MAX + 1))),
			auth.parse_conf(auth.conf('prom', sha_hash('6', auth.ROUNDS_MAX))),
		]);
	});
});
