'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as proc from 'prometheus_exporter.proc';

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

	// fields() splits on strings where it can, for speed; it must split as
	// the regex does, on any line: every whitespace character, in any run.
	const SPACE_RUN = /\s+/;

	prop('splits as split(trim(line), /\\s+/) does, on any line',
		gen.array(gen.elements('a', 'b7', ' ', '  ', '\t', '\n', '\v', '\f', '\r', ' \t'), { min_len: 0, max_len: 12 }), (parts) => {
			let line = join('', parts);
			let t = trim(line);

			assert.match(t == '' ? [] : split(t, SPACE_RUN), proc.fields(line), sprintf('%J', line));
		});
});

describe('proc.rows', () => {
	it('is the fields of each line, [] for a blank one, and null for a file that cannot be read', () => {
		with_fs({ '/f': 'a b\n\nc  d\te\n', '/g': 'a b\n\nc d\n', '/gone': null }, (fs) => {
			assert.match([ [ [ 'a', 'b' ], [], [ 'c', 'd', 'e' ] ], [ [ 'a', 'b' ], [], [ 'c', 'd' ] ], null ],
				[ proc.rows(fs, '/f'), proc.rows(fs, '/g'), proc.rows(fs, '/gone') ]);
		});
	});

	// rows() splits each line on ' ' when one look at the whole text says
	// it can: it must give what fields() gives of each of lines(), of any
	// text.
	prop('gives what fields() gives of each line, of any text',
		gen.array(gen.elements('a', 'b7', ' ', '  ', '\t', '\n', '\n', '\v', '\f', '\r', ' \n', '\n '), { min_len: 0, max_len: 16 }), (parts) => {
			let text = join('', parts);

			with_fs({ '/f': text }, (fs) => assert.match(map(proc.lines(fs, '/f'), proc.fields), proc.rows(fs, '/f'), sprintf('%J', text)));
		});
});

// An auxiliary vector of `pairs`, then AT_NULL, in words of `size` bytes.
function vector(pairs, size, le) {
	let s = '';

	for (let p in [ ...pairs, [ 0, 0 ] ])
		for (let v in p)
			for (let i = 0; i < size; i++) {
				let shift = 8 * (le ? i : size - 1 - i);
				s += chr(shift < 32 ? (v >> shift) & 0xff : 0);
			}

	return s;
}

describe('proc.auxv', () => {
	it('reads the types and values of a vector, the page size and the clock tick among them', () => {
		for (let layout in [ [ 8, true ], [ 4, true ], [ 8, false ], [ 4, false ] ]) {
			let v = proc.auxv(vector([ [ 16, 0x8ff ], [ proc.AT_PAGESZ, 4096 ], [ proc.AT_CLKTCK, 100 ] ], layout[0], layout[1]));

			assert.match([ 4096, 100 ], [ v?.[proc.AT_PAGESZ], v?.[proc.AT_CLKTCK] ], sprintf('%J', layout));
		}
	});

	// auxv() reads a word with its loop written out, and a type by its zero
	// bytes: it must read any bytes as the loop of a word a byte did, every
	// type with its word.
	prop('reads any bytes as reading each word a byte at a time does',
		gen.tuple(gen.array(gen.tuple(gen.oneof(gen.int(0, 70), gen.elements(0x100, 0x10006, 1 << 31)),
			gen.oneof(gen.int(0, 70000), gen.elements(4096, 1 << 31, 0xffffffff, 0x7fffffff))), { min_len: 0, max_len: 6 }),
			gen.elements(8, 4), gen.bool(), gen.array(gen.int(0, 255), { min_len: 0, max_len: 3 })), (t) => {
			let bytes = vector(t[0], t[1], t[2]) + join('', map(t[3], chr));

			function word(s, at, size, le) {
				let v = 0;

				for (let i = 0; i < size; i++)
					v = v * 256 + ord(s, le ? at + size - 1 - i : at + i);

				return v;
			}

			// auxv() as it read each word a byte at a time.
			function reference(bytes) {
				let n = length(bytes ?? '');

				for (let l in [ [ 8, true ], [ 4, true ], [ 8, false ], [ 4, false ] ]) {
					let size = l[0], le = l[1], pair = size * 2, out = {};

					if (!n || n % pair)
						continue;

					for (let at = 0; at < n; at += pair) {
						let w = word(bytes, at, size, le);

						if (w >= 64 || w < 0)
							break;
						if (w == 0) {
							let ps = out[proc.AT_PAGESZ];

							if (at + pair == n && ps >= 1024 && !(ps & (ps - 1)))
								return out;
							break;
						}

						out[w] = word(bytes, at + size, size, le);
					}
				}

				return null;
			}

			assert.match(reference(bytes), proc.auxv(bytes), sprintf('%J', t));
		});

	it('is null for what is not a vector, or one without a page size', () => {
		assert.match([ null, null, null, null ],
			[ proc.auxv(null), proc.auxv(''), proc.auxv('garbage!'), proc.auxv(vector([ [ proc.AT_CLKTCK, 100 ] ], 8, true)) ]);
	});
});
