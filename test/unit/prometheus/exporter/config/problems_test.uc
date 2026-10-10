'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as problems from 'prometheus.exporter.config.problems';

// The codes the module exports, by their names: every uppercase export but CODES.
function exported() {
	return sort(filter(keys(problems), (k) => match(k, /^[A-Z_]+$/) && k != 'CODES'));
}

// A problem of `code` with every argument it takes, and a value when it takes one.
function sample(code, value) {
	let args = {};

	for (let a in problems.CODES[code].args)
		args[a] = 7;
	if (problems.CODES[code].value && value != null)
		args.value = value;

	return problems.problem(code, args);
}

describe('config.problems.CODES', () => {
	it('spells every code as its own name, and has each the module exports', () => {
		for (let name in exported())
			assert.match(name, problems[name]);
		assert.match(exported(), sort(keys(problems.CODES)));
	});

	it('gives every code its English, with its arguments', () => {
		for (let code in keys(problems.CODES)) {
			let text = problems.english(sample(code, 'x'));

			assert.match(true, type(text) == 'string' && length(text) > 0, code);
			assert.match(true, index(text, 'null') < 0, code);
		}
	});
});

describe('config.problems.english', () => {
	it('says what a value\'s option expected, and what it got', () => {
		assert.match([
			'expected a boolean, got "maybe"',
			'expected an integer, got "1.5"',
			'expected a single value, got [ "a", "b" ]',
			'expected an integer from 1 to 65535, got 0',
			'expected an integer of 0 or more, got -1',
			'expected an absolute path, got "srv/prom"',
			'expected a regular expression, got "(pg"',
			'expected an interface name or *, got ""',
		], [
			problems.english(problems.problem(problems.BOOLEAN, { value: 'maybe' })),
			problems.english(problems.problem(problems.INTEGER, { value: '1.5' })),
			problems.english(problems.problem(problems.SINGLE, { value: [ 'a', 'b' ] })),
			problems.english(problems.problem(problems.RANGE, { min: 1, max: 65535, value: 0 })),
			problems.english(problems.problem(problems.UINTEGER, { value: -1 })),
			problems.english(problems.problem(problems.ABSOLUTE_PATH, { value: 'srv/prom' })),
			problems.english(problems.problem(problems.REGEX, { value: '(pg' })),
			problems.english(problems.problem(problems.INTERFACE, { value: '' })),
		]);
	});

	it('leaves out the value a secret option\'s problem does not hold', () => {
		assert.match([
			'expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$',
			'expected a hash of at most 2000 rounds, which a scrape computes to check the password (hash_password makes one of 1000; one without rounds= has 5000)',
		], [
			problems.english(problems.problem(problems.CRYPT)),
			problems.english(problems.problem(problems.CRYPT_ROUNDS, { max: 2000 })),
		]);
	});

	it('says the whole of what is wrong with options that go together', () => {
		assert.match([
			'basic auth needs the hash of a password along with auth_user',
			'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
		], map([ problems.AUTH_NEEDS_PASSWORD, problems.AUTH_NEEDS_TLS ],
			(code) => problems.english(problems.problem(code))));
	});

	prop('says what a value\'s code got exactly when the problem holds it',
		gen.tuple(gen.elements(...keys(problems.CODES)), gen.oneof(gen.int(-100, 100), gen.alphanumeric({ min_len: 0, max_len: 6 }), gen.constant(null))), (t) => {
			let p = sample(t[0], t[1]);

			assert.match(problems.CODES[t[0]].value && t[1] != null, index(problems.english(p), ', got ') >= 0);
			assert.match(problems.english(p), substr(problems.message('o', p), 3));
		});

	it('spells what a value\'s option expected, as the datatypes say what they take', () => {
		assert.match('an integer from 1 to 30', problems.expected(problems.problem(problems.RANGE, { min: 1, max: 30 })));
	});
});

describe('config.problems.problem', () => {
	it('makes { code, ...args }', () => {
		assert.match({ code: 'RANGE', min: 1, max: 9, value: 0 }, problems.problem(problems.RANGE, { min: 1, max: 9, value: 0 }));
		assert.match({ code: 'AUTH_NEEDS_TLS' }, problems.problem(problems.AUTH_NEEDS_TLS));
	});

	it('dies of a code it does not have, or of an argument the code does not take', () => {
		for (let bad in [ [ 'NOPE', null ], [ problems.RANGE, { step: 2 } ], [ problems.AUTH_NEEDS_TLS, { value: 'x' } ] ]) {
			let died = false;

			try {
				problems.problem(bad[0], bad[1]);
			} catch (e) {
				died = true;
			}

			assert.match(true, died, bad[0]);
		}
	});
});
