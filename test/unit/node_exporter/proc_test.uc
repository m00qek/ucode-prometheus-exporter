'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as proc from 'node_exporter.proc';

function with_fs(data, cb) {
	mock.inject('fs', { strict: true, data }, cb);
}

describe('proc.first_line', () => {
	it('is the first line without its newline', () => {
		with_fs({ '/f': 'a b\nc\n' }, (fs) => assert.match('a b', proc.first_line(fs, '/f')));
	});

	it('is null for a file that cannot be read, and empty for an empty one', () => {
		with_fs({ '/gone': null, '/empty': '' }, (fs) => {
			assert.match([ null, '' ], [ proc.first_line(fs, '/gone'), proc.first_line(fs, '/empty') ]);
		});
	});
});

describe('proc.lines', () => {
	it('splits without a trailing empty line', () => {
		with_fs({ '/f': 'a\nb\n', '/g': 'a\nb' }, (fs) => {
			assert.match([ [ 'a', 'b' ], [ 'a', 'b' ] ], [ proc.lines(fs, '/f'), proc.lines(fs, '/g') ]);
		});
	});

	it('is null for a file that cannot be read', () => {
		with_fs({ '/gone': null }, (fs) => assert.match(null, proc.lines(fs, '/gone')));
	});

	prop('gives back the lines a file was written from',
		gen.array(gen.string({ min_len: 0, max_len: 12 }), { min_len: 1, max_len: 8 }), (l) => {
			with_fs({ '/f': join('\n', l) + '\n' }, (fs) => assert.match(l, proc.lines(fs, '/f')));
		});
});

describe('proc.each_line', () => {
	it('calls back once per line, in order', () => {
		with_fs({ '/f': 'one\ntwo\n' }, (fs) => {
			let seen = [];
			assert.match(true, proc.each_line(fs, '/f', (l) => push(seen, l)));
			assert.match([ 'one', 'two' ], seen);
		});
	});

	it('is false for a file that cannot be read', () => {
		with_fs({ '/gone': null }, (fs) => assert.match(false, proc.each_line(fs, '/gone', () => null)));
	});
});

describe('proc.fields', () => {
	it('splits on any run of whitespace, ignoring the ends', () => {
		assert.match([ 'a', 'b', 'c' ], proc.fields('  a \t b\tc  '));
	});

	it('is empty for null and for blank lines', () => {
		assert.match([ [], [] ], [ proc.fields(null), proc.fields(' \t ') ]);
	});

	prop('recovers fields joined by any whitespace',
		gen.tuple(gen.array(gen.alphanumeric({ min_len: 1, max_len: 6 }), { min_len: 0, max_len: 6 }),
			gen.elements(' ', '\t', '  ', ' \t ')), (t) => {
			assert.match(t[0], proc.fields(t[1] + join(t[1], t[0]) + t[1]));
		});
});
