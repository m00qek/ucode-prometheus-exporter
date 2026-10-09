'use strict';

import { describe, it, prop, gen, assert, regex } from 'utest';
import * as format from 'prometheus_exporter.exposition.format';
import * as exposition from 'prometheus_exporter.exposition';

const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;

const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

describe('exposition.format.sanitize', () => {
	it('makes disallowed characters underscores', () => {
		assert.match([ 'node_memory_Active_anon_', 'a:b', 'a_b' ],
			[ format.sanitize('node_memory_Active(anon)'), format.sanitize('a:b'), format.sanitize('a:b', true) ]);
	});

	it('prefixes a leading digit, and gives nothing a name', () => {
		assert.match([ '_1x', '_' ], [ format.sanitize('1x'), format.sanitize('') ]);
	});

	prop('always gives a valid name, and is idempotent', gen.ascii({ min_len: 0, max_len: 16 }), (s) => {
		let metric = format.sanitize(s), label = format.sanitize(s, true);

		assert.match(regex(METRIC_NAME), metric);
		assert.match(regex(LABEL_NAME), label);
		assert.match([ metric, label ], [ format.sanitize(metric), format.sanitize(label, true) ]);
	});
});

describe('exposition.format.format_value', () => {
	it('spells special doubles and booleans as the format does', () => {
		assert.match([ 'NaN', '+Inf', '-Inf', '1', '0', '0.5' ],
			map([ NaN, Infinity, -Infinity, true, false, 0.5 ], format.format_value));
	});

	it('reads numeric strings, trimmed, including sysfs hex', () => {
		assert.match([ '42', '-1', '1.5', '4099', '1000', '+Inf', 'NaN' ],
			map([ '42\n', ' -1 ', '1.5', '0x1003', '1e3', 'Inf', 'NaN' ], format.format_value));
	});

	it('is null for what is not a number', () => {
		assert.match([ null, null, null, null, null, null ],
			map([ '', '  ', 'up', '12abc', null, {} ], format.format_value));
	});

	it('writes a double so that it reads back as itself, in as few digits as ucode writes most', () => {
		assert.match([ '0.1', '0.25', '2', '1e+21', '0.3333333333333333', '123456789012345.67', '0.30000000000000004', '-0' ],
			map([ 0.1, 0.25, 2.0, 1e21, 1 / 3.0, 123456789012345.67, 0.1 + 0.2, -0.0 ], (d) => format.format_value(d)));
	});

	prop('reads every double it writes back as that double', gen.tuple(gen.int(-2147483647, 2147483647), gen.int(1, 2147483647), gen.int(-30, 30)),
		(t) => {
			let d = (t[0] / (t[1] * 1.0)) * (10.0 ** t[2]);

			assert.match(true, +format.format_value(d) == d, `${d}`);
		});

	prop('keeps integers exact, as numbers and as procfs text', gen.int(-2147483648, 2147483647), (n) => {
		assert.match([ '' + n, '' + n ], [ format.format_value(n), format.format_value(` ${n}\n`) ]);
	});
});

describe('exposition.format.utf8_valid', () => {
	it('takes ASCII and well-formed UTF-8 of one to four bytes', () => {
		assert.match([ true, true, true, true, true ],
			map([ '', 'eth0', 'café', 'Wi‑Fi ✓', 'emoji \xf0\x9f\x93\xb6' ], format.utf8_valid));
	});

	// As Go's utf8.ValidString, which Prometheus reads a scrape with.
	it('refuses a stray byte, a cut sequence, an overlong form, a surrogate and what is past U+10FFFF', () => {
		assert.match([ false, false, false, false, false, false, false ],
			map([ 'caf\xe9', 'caf\xc3', '\xe2\x82', '\xc0\xaf', '\xe0\x80\xaf', '\xed\xa0\x80', '\xf4\x90\x80\x80' ], format.utf8_valid));
	});

	prop('takes every string of code points', gen.array(gen.int(1, 0x10ffff), { min_len: 0, max_len: 8 }), (cps) => {
		assert.match(true, format.utf8_valid(join('', map(filter(cps, (c) => c < 0xd800 || c > 0xdfff), (c) => uchr(c)))));
	});
});

// A label set as the format writes it, each pair on its own: its names
// sanitized, its values spelled and escaped; null where Prometheus would
// refuse it (two names that are one, a value that is not UTF-8).
function expected_labels(labels) {
	let pairs = [];
	let seen = {};

	for (let name, value in labels) {
		if (!(type(value) in [ 'string', 'int', 'double', 'bool' ]))
			continue;

		let s = format.sanitize(name, true);
		let v = (type(value) == 'string') ? value : format.format_value(value);

		if (seen[s] || !format.utf8_valid(v))
			return null;
		seen[s] = true;
		push(pairs, [ s, v ]);
	}

	return format.format_labels(pairs);
}

describe('exposition.format.label_text', () => {
	// A set is written in one pass, its values escaped and read as UTF-8
	// only when they need it, each name's text kept from the first time:
	// what its pairs, one by one, are, the first time and after.
	prop('writes a set as its pairs one by one, the first time and after, or is null',
		gen.array(gen.tuple(
			gen.elements('src', 'dst', 'if-name', 'if_name', '1x', ''),
			gen.oneof(gen.elements('', 'eth0', 'a"b', 'a\\b', 'x\ny', 'café', 'caf\xe9', '\xc3', '\xa9', 'é"'),
				gen.int(-3, 3), gen.elements(0.5, 1 / 3.0, true, null, [ 1 ]))),
			{ min_len: 0, max_len: 4 }), (pairs) => {
			let labels = {};

			for (let p in pairs)
				labels[p[0]] = p[1];

			let want = expected_labels(labels);

			assert.match([ want, want ], [ format.label_text(labels), format.label_text(labels) ], sprintf('%J', labels));
		});

	it('writes a set, escaping only the values that need it', () => {
		assert.match([ '', '', '{a="1",b="x"}', '{s="a\\\\b",u="café"}' ],
			[ format.label_text(null), format.label_text({}), format.label_text({ a: 1, b: 'x' }), format.label_text({ s: 'a\\b', u: 'café' }) ]);
	});

	it('is null for names that are one once sanitized, or a value that is not valid UTF-8, and label_problem says which', () => {
		let clash = { 'if-name': 'a', if_name: 'b' };
		let latin1 = { ssid: 'caf\xe9' };

		assert.match([ null, null ], [ format.label_text(clash), format.label_text(latin1) ]);
		assert.match([
			{ label: 'if_name', why: "labels 'if-name' and 'if_name' are both 'if_name' once sanitized" },
			{ label: 'ssid', why: 'its value is not valid UTF-8' },
			{ label: null, why: 'labels must be an object, or what out.labels() made, not a string of its own' },
			{ label: null, why: 'labels must be an object, or what out.labels() made, not array' },
			null,
		], map([ clash, latin1, 'eth0 up', [ 'x' ], { a: 'b' } ], format.label_problem));
	});
});

describe('format.header, as render() writes it', () => {
	// render() writes a header itself when its HELP has nothing to escape:
	// it must write what header() writes.
	prop('writes each family\'s header as header() does, whatever its HELP',
		gen.array(gen.tuple(gen.oneof(gen.constant(null), gen.constant(''), gen.string({ min_len: 1, max_len: 12, charset: 'ab \\\n"' })),
			gen.elements('gauge', 'counter', 'untyped')), { min_len: 1, max_len: 4 }), (spec) => {
			let fams = map(spec, (s, i) => ({ name: `f${i}`, type: s[1], help: s[0], lines: [ `f${i} ${i}` ], values: [ `${i}` ] }));

			assert.match(join('\n', map(fams, (f) => format.header(f) + '\n' + f.lines[0])) + '\n', exposition.render(fams));
		});
});
