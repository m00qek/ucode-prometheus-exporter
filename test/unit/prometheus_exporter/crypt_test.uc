'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as crypt from 'prometheus_exporter.crypt';

// What OpenSSL's `openssl passwd` (-1, -5, -6) prints for these, and `uhttpd
// -m secret` on OpenWrt 25.12 (musl).
const KNOWN = [
	[ 'Hello world!', '$1$saltstri$YMyguxXMBpd2TEZ.vS/3q1' ],
	[ 'secret', '$1$$ysVNzQc4CTMkp5daOdZ.3/' ],
	[ 'Hello world!', '$5$saltstring$5B8vYYiY.CVt1RlTTf8KbXBH3hsxY/GNooZaBBGWEc5' ],
	[ 'a', '$5$rounds=1000$x$SQwVBUy5LmuITCN/Pzolg3R9CfHva3WZZYnD1O10qB5' ],
	[ 'Hello world!', '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1' ],
	[ 'Hello world!', '$6$toolongsaltstrin$iGlL7EUUfzNQx59x3ydJZ.zXPMUu1dOynSEl/vcNhLlas77qD0DzRswhhB6LdrXTz250at0syAfUXra.XrxAI1' ],
	[ 'Hello world!', '$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v.' ],
];

// 300 'x': longer than one SHA-512 block, and than KEY_MAX.
const LONG = '$6$abc$ZE4Pk3kxdvXasbkMczcXYY.xL/yjSvafp4EosxKhMrtLYoy9BXWLMrRcsct2IgJaDwFFoeY5qS0JqbkIYFMiM0';

function chars(n) {
	return gen.string({ len: n, charset: crypt.ITOA64 });
}

function salt(max) {
	return gen.string({ min_len: 0, max_len: max, charset: crypt.ITOA64 });
}

// Any hash of the formats, by its form: what musl's crypt could have made.
const HASH = gen.oneof(
	gen.map(gen.tuple(salt(8), chars(22)), (t) => `$1$${t[0]}$${t[1]}`),
	gen.map(gen.tuple(gen.elements('5', '6'), gen.optional(gen.int(crypt.ROUNDS_MIN, crypt.ROUNDS_MAX)), salt(16), chars(86)),
		(t) => '$' + t[0] + '$' + (t[1] != null ? 'rounds=' + t[1] + '$' : '') + t[2] + '$' + substr(t[3], 0, t[0] == '5' ? 43 : 86))
);

const PASSWORD = gen.string({ min_len: 1, max_len: 40, charset: 'abcXYZ019 !:$%&/\\"\'' });

describe('crypt.crypt', () => {
	it('hashes as musl and OpenSSL do, for each format', () => {
		for (let k in KNOWN)
			assert.match(k[1], crypt.crypt(k[0], k[1]));
	});

	it('hashes up to KEY_MAX bytes with $5$ and $6$, as musl does, and $1$ any', () => {
		let x = (n) => join('', map(split(sprintf(`%${n}s`, ''), ''), () => 'x'));

		assert.match([ null, true ], [ crypt.crypt(x(300), LONG), crypt.crypt(x(300), '$1$ab$' + substr(LONG, 7, 22)) != null ]);
		assert.match(true, crypt.crypt(x(crypt.KEY_MAX), '$6$abc$' + substr(LONG, 7)) != null);
	});

	it('takes no key with a NUL, which a C string ends at, and no setting that is not a hash', () => {
		assert.match([ null, null, null ], [
			crypt.crypt('a\0b', KNOWN[0][1]),
			crypt.crypt('secret', 'secret'),
			crypt.crypt(null, KNOWN[0][1]),
		]);
	});
});

describe('crypt.verify', () => {
	it('takes the password of a hash and no other', () => {
		for (let k in KNOWN)
			assert.match([ true, false ], [ crypt.verify(k[0], k[1]), crypt.verify(k[0] + ' ', k[1]) ]);
	});

	it('does not take the hash itself as the password', () => {
		for (let k in KNOWN)
			assert.match(false, crypt.verify(k[1], k[1]));
	});

	prop('takes a password hashed by hash(), and no other', gen.tuple(PASSWORD, PASSWORD, gen.string({ len: crypt.SALT_BYTES, charset: 'abc\x01\xff' })),
		(t) => {
			let h = crypt.hash(t[0], t[2], crypt.ROUNDS_MIN);

			assert.match([ true, t[0] == t[1] ], [ crypt.verify(t[0], h), crypt.verify(t[1], h) ]);
		}, { runs: 25 });
});

describe('crypt.is_hash', () => {
	it('takes the hashes of each format', () => {
		for (let k in KNOWN)
			assert.match(true, crypt.is_hash(k[1]));
	});

	prop('takes any hash of the formats', HASH, (h) => {
		assert.match(true, crypt.is_hash(h), h);
	});

	prop('refuses a hash with a character more or less, or one out of the alphabet', gen.tuple(HASH, gen.int(0, 200), gen.elements(':', '!', ' ', '\n', '*', '+')),
		(t) => {
			let h = t[0], i = t[1] % length(h);

			assert.match([ false, false, false ], [
				crypt.is_hash(substr(h, 0, length(h) - 1)),
				crypt.is_hash(h + '.'),
				crypt.is_hash(substr(h, 0, i) + t[2] + substr(h, i + 1)),
			], h);
		});

	prop('refuses whatever does not start with $1$, $5$ or $6$', gen.ascii({ min_len: 0, max_len: 100 }), (s) => {
		if (!match(s, /^\$[156]\$/))
			assert.match(false, crypt.is_hash(s), s);
	});

	// is_hash counts lengths and matches the parts without a count, which
	// musl compiles into hundreds of kB: it must take what these take.
	const AS_ONE = [
		/^\$1\$[.\/0-9A-Za-z]{0,8}\$[.\/0-9A-Za-z]{22}$/,
		/^\$5\$(rounds=[1-9][0-9]{3,6}\$)?[.\/0-9A-Za-z]{0,16}\$[.\/0-9A-Za-z]{43}$/,
		/^\$6\$(rounds=[1-9][0-9]{3,6}\$)?[.\/0-9A-Za-z]{0,16}\$[.\/0-9A-Za-z]{86}$/,
	];

	function as_one(s) {
		return length(filter(AS_ONE, (re) => match(s, re))) > 0;
	}

	prop('takes what the formats as a regex each take, of hashes cut, grown or changed anywhere',
		gen.tuple(HASH, gen.int(0, 200), gen.int(0, 3), gen.elements('$', '.', 'a', '0', ':', '\n', 'rounds=', '$1$', '$5$', '$6$', '')),
		(t) => {
			let h = t[0], i = t[1] % (length(h) + 1);
			let cut = substr(h, 0, i) + t[3] + substr(h, i + t[2]);

			assert.match(as_one(cut), crypt.is_hash(cut), cut);
		});

	prop('takes what the formats as a regex each take, of any text of $ and the alphabet',
		gen.string({ min_len: 0, max_len: 120, charset: '$156.ab0rounds=9' }), (s) => {
			assert.match(as_one(s), crypt.is_hash(s), s);
		});

	it('refuses DES, bcrypt, $p$, rounds musl would rewrite, and plain text', () => {
		let digest86 = substr(KNOWN[4][1], 15);

		assert.match([ false, false, false, false, false, false, false, false ], map([
			'ab01FAX.bQRSU',
			'$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy',
			'$p$root',
			'$6$rounds=999$salt$' + digest86,
			'$6$rounds=05000$salt$' + digest86,
			'$6$rounds=10000000$salt$' + digest86,
			'secret',
			null,
		], crypt.is_hash));
	});
});

describe('crypt.rounds', () => {
	it('is 1000 for MD5-crypt, those a SHA-crypt hash names, else 5000', () => {
		assert.match([ 1000, 1000, 5000, 1000, 5000, 10000, null, null ], map([
			KNOWN[0][1], KNOWN[1][1], KNOWN[2][1], KNOWN[3][1], KNOWN[4][1], KNOWN[6][1], 'secret', '$6$rounds=10000000$salt$' + substr(KNOWN[4][1], 15),
		], crypt.rounds));
	});

	prop('is the rounds of any hash of the formats, and what hash() was given', gen.tuple(HASH, gen.int(crypt.ROUNDS_MIN, crypt.ROUNDS_MAX)), (t) => {
		let named = match(t[0], /^\$[56]\$rounds=([0-9]+)\$/);

		assert.match(named ? +named[1] : (substr(t[0], 0, 3) == '$1$' ? 1000 : crypt.ROUNDS_DEFAULT), crypt.rounds(t[0]), t[0]);
		assert.match(t[1], crypt.rounds('$6$rounds=' + t[1] + '$salt$' + substr(KNOWN[4][1], 14)));
	});
});

describe('crypt.hash', () => {
	it('makes a $6$ hash, salted with 16 characters of the 12 bytes it is given', () => {
		let h = crypt.hash('pw', 'abcdefghijkl', null);

		assert.match([ true, true, 3 + 16 + 1 + 86 ], [ crypt.is_hash(h), match(h, /^\$6\$[.\/0-9A-Za-z]{16}\$/) != null, length(h) ]);
		assert.match(true, crypt.hash('pw', 'abcdefghijkl', null) == h);
		assert.match(false, crypt.hash('pw', 'abcdefghijkm', null) == h);
	});

	it('names the rounds it is given', () => {
		assert.match(true, match(crypt.hash('pw', 'abcdefghijkl', 1000), /^\$6\$rounds=1000\$[.\/0-9A-Za-z]{16}\$/) != null);
	});
});

describe('crypt.same', () => {
	prop('is equality of strings', gen.tuple(gen.string({ max_len: 4, charset: 'ab' }), gen.string({ max_len: 4, charset: 'ab' })), (t) => {
		assert.match(t[0] == t[1], crypt.same(t[0], t[1]));
	});

	it('takes strings only', () => {
		assert.match([ false, false ], [ crypt.same(null, null), crypt.same(1, 1) ]);
	});
});
