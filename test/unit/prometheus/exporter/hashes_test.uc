'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as hashes from 'prometheus.exporter.hashes';
import * as crypt from 'prometheus.exporter.crypt';
import * as auth from 'prometheus.exporter.auth';

// What crypt and auth compute and check by these is their tests'
// (crypt_test.uc, auth_test.uc): here, that they are these, and what the
// config's datatypes take of them without loading either.

const SALT = gen.string({ min_len: 0, max_len: 16, charset: crypt.ITOA64 });

describe('hashes, under crypt\'s and auth\'s names', () => {
	it('is what crypt and auth export', () => {
		assert.match([ true, true, true, true, true ], [
			crypt.is_hash === hashes.is_hash, crypt.rounds === hashes.rounds,
			auth.is_user === hashes.is_user, auth.is_hash === hashes.is_auth_hash,
			auth.ROUNDS_MAX == hashes.AUTH_ROUNDS_MAX,
		]);
		assert.match(crypt.ROUNDS_DEFAULT, hashes.ROUNDS_DEFAULT);
	});
});

describe('hashes.is_hash and rounds', () => {
	it('takes MD5-crypt at 1000 rounds, and SHA-crypt at those it names or the default', () => {
		let md5 = '$1$saltstri$YMyguxXMBpd2TEZ.vS/3q1';
		let sha = crypt.hash('secret', 'abcdefghijkl', 1000);

		assert.match([ 1000, 1000, hashes.ROUNDS_DEFAULT ],
			[ hashes.rounds(md5), hashes.rounds(sha), hashes.rounds(crypt.hash('secret', 'abcdefghijkl', null)) ]);
	});

	it('takes nothing else, and no hash of rounds musl would write otherwise', () => {
		assert.match([ false, false, false, false, false ], map([
			null, '', 'plain', '$2b$10$abcdefghijklmnopqrstuu', '$5$rounds=01000$x$' + substr(crypt.ITOA64, 0, 43),
		], hashes.is_hash));
	});

	prop('gives SHA-crypt\'s rounds as the hash names them', gen.tuple(gen.int(crypt.ROUNDS_MIN, crypt.ROUNDS_MIN + 50), SALT), (t) => {
		assert.match(t[0], hashes.rounds(crypt.sha_crypt('6', 'x', t[1], t[0])));
	});
});

describe('hashes.is_auth_hash', () => {
	it('takes a hash of up to AUTH_ROUNDS_MAX rounds, and none of more', () => {
		assert.match([ true, true, false ], map([
			crypt.hash('secret', 'abcdefghijkl', 1000),
			crypt.sha_crypt('5', 'secret', 'x', hashes.AUTH_ROUNDS_MAX),
			crypt.sha_crypt('5', 'secret', 'x', hashes.AUTH_ROUNDS_MAX + 1),
		], hashes.is_auth_hash));
	});
});

describe('hashes.is_user', () => {
	it('takes 1 to 64 bytes without ":", white space or control characters', () => {
		assert.match([ true, true, false, false, false, false ],
			map([ 'prometheus', sprintf('%064d', 0), '', 'a:b', 'a b', sprintf('%065d', 0) ], hashes.is_user));
	});
});
