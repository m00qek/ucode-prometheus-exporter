'use strict';

import { describe, it, prop, gen, assert, contains, regex } from 'utest';
import * as exposition from 'node_exporter.exposition';

const METRIC_NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL_NAME = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

function text_of(fill) {
	let out = exposition.recorder();
	fill(out);
	return exposition.render(out.families());
}

function lines(text) {
	return text == '' ? [] : split(rtrim(text, '\n'), '\n');
}

function parse_error(text) {
	let res = exposition.parse(text);
	return res.ok ? null : res.details;
}

describe('exposition.sanitize', () => {
	it('makes disallowed characters underscores', () => {
		assert.match([ 'node_memory_Active_anon_', 'a:b', 'a_b' ],
			[ exposition.sanitize('node_memory_Active(anon)'), exposition.sanitize('a:b'), exposition.sanitize('a:b', true) ]);
	});

	it('prefixes a leading digit, and gives nothing a name', () => {
		assert.match([ '_1x', '_' ], [ exposition.sanitize('1x'), exposition.sanitize('') ]);
	});

	prop('always gives a valid name, and is idempotent', gen.ascii({ min_len: 0, max_len: 16 }), (s) => {
		let metric = exposition.sanitize(s), label = exposition.sanitize(s, true);

		assert.match(regex(METRIC_NAME), metric);
		assert.match(regex(LABEL_NAME), label);
		assert.match([ metric, label ], [ exposition.sanitize(metric), exposition.sanitize(label, true) ]);
	});
});

describe('exposition.format_value', () => {
	it('spells special doubles and booleans as the format does', () => {
		assert.match([ 'NaN', '+Inf', '-Inf', '1', '0', '0.5' ],
			map([ NaN, Infinity, -Infinity, true, false, 0.5 ], exposition.format_value));
	});

	it('reads numeric strings, trimmed, including sysfs hex', () => {
		assert.match([ '42', '-1', '1.5', '4099', '1000', '+Inf', 'NaN' ],
			map([ '42\n', ' -1 ', '1.5', '0x1003', '1e3', 'Inf', 'NaN' ], exposition.format_value));
	});

	it('is null for what is not a number', () => {
		assert.match([ null, null, null, null, null, null ],
			map([ '', '  ', 'up', '12abc', null, {} ], exposition.format_value));
	});

	prop('keeps integers exact, as numbers and as procfs text', gen.int(-2147483648, 2147483647), (n) => {
		assert.match([ '' + n, '' + n ], [ exposition.format_value(n), exposition.format_value(` ${n}\n`) ]);
	});
});

describe('exposition.recorder', () => {
	it('declares a family once and chains its samples', () => {
		let text = text_of((out) => {
			out.gauge('g', 'A gauge.')({ a: 'x' }, 1)({ a: 'y' }, 2);
			out.gauge('g')({ a: 'z' }, 3);
		});

		assert.match([ '# HELP g A gauge.', '# TYPE g gauge', 'g{a="x"} 1', 'g{a="y"} 2', 'g{a="z"} 3' ], lines(text));
	});

	it('skips values that are not numbers, and writes no family without samples', () => {
		assert.match([ '# TYPE c counter', 'c 1' ], lines(text_of((out) => {
			out.counter('c')(null, 'n/a')(null, 1);
			out.gauge('never')(null, null);
		})));
	});

	it('leaves out null labels and spells the other types', () => {
		assert.match([ '# TYPE u untyped', 'u{i="3",d="0.5",b="1"} 1' ], lines(text_of((out) => {
			out.untyped('u')({ n: null, i: 3, d: 0.5, b: true, o: {} }, 1);
		})));
	});

	it('escapes label values', () => {
		assert.match([ '# TYPE g gauge', 'g{s="a\\\\b\\"c\\nd"} 1' ], lines(text_of((out) => {
			out.gauge('g')({ s: 'a\\b"c\nd' }, 1);
		})));
	});

	it('keeps the first type of a name and reports the conflict', () => {
		let out = exposition.recorder();
		out.gauge('x')(null, 1);
		out.counter('x')(null, 2);

		assert.match([ '# TYPE x gauge', 'x 1' ], lines(exposition.render(out.families())));
		assert.match([ 'x' ], out.conflicts());
	});

	it('adds valid exposition text, and refuses invalid text whole', () => {
		let out = exposition.recorder();

		assert.match(true, out.parse('# TYPE t gauge\nt{a="1"} 5\n').ok);
		assert.match('EXPOSITION_INVALID', out.parse('t 1\nbroken line here\n').error);
		assert.match([ '# TYPE t gauge', 't{a="1"} 5' ], lines(exposition.render(out.families())));
	});
});

describe('exposition.merge', () => {
	it('merges families by name in the order they first appear', () => {
		let a = exposition.recorder(), b = exposition.recorder();
		a.gauge('first')(null, 1);
		b.gauge('second')(null, 2);
		b.gauge('first')({ from: 'b' }, 3);

		let merged = exposition.merge([ a.families(), b.families() ]);
		assert.match([ '# TYPE first gauge', 'first 1', 'first{from="b"} 3', '# TYPE second gauge', 'second 2' ],
			lines(exposition.render(merged.families)));
		assert.match([], merged.conflicts);
	});

	it('reports a name two collectors give different types', () => {
		let a = exposition.recorder(), b = exposition.recorder();
		a.gauge('x')(null, 1);
		b.counter('x')(null, 2);

		assert.match([ 'x' ], exposition.merge([ a.families(), b.families() ]).conflicts);
	});
});

describe('exposition.render', () => {
	it('is empty for no samples', () => {
		assert.match('', exposition.render([]));
	});

	it('escapes HELP text', () => {
		assert.match([ '# HELP h a\\\\b\\nc', '# TYPE h gauge', 'h 1' ],
			lines(text_of((out) => out.gauge('h', 'a\\b\nc')(null, 1))));
	});

	it('omits zero counters when asked, and a counter family left empty', () => {
		let out = exposition.recorder();
		out.counter('c')({ i: 'a' }, 0)({ i: 'b' }, 7);
		out.counter('z')(null, 0);
		out.gauge('g')(null, 0);

		assert.match([ '# TYPE c counter', 'c{i="b"} 7', '# TYPE g gauge', 'g 0' ],
			lines(exposition.render(out.families(), { omit_zero_counters: true })));
	});
});

describe('exposition.parse', () => {
	it('reads families, labels with escapes, timestamps, and histogram series', () => {
		let res = exposition.parse(
			'# HELP h Latency.\n# TYPE h histogram\nh_bucket{le="1"} 2\nh_bucket{le="+Inf"} 3\nh_sum 4.5\nh_count 3\n' +
			'# a comment\n\nu{a="x\\"y\\\\z\\n",b="",} 1 1700000000000\n');

		assert.match(true, res.ok);
		assert.match([ 'h', 'u' ], map(res.data, (f) => f.name));
		assert.match([ 'histogram', 4, 'Latency.' ], [ res.data[0].type, length(res.data[0].samples), res.data[0].help ]);
		assert.match({ name: 'u', labels: [ [ 'a', 'x"y\\z\n' ], [ 'b', '' ] ], value: '1', ts: '1700000000000' },
			res.data[1].samples[0]);
	});

	it('names the line that breaks the format', () => {
		assert.match([
			'line 2: malformed label set',
			'line 1: value \'up\' is not a number',
			'line 2: second TYPE for \'a\'',
			'line 2: TYPE for \'a\' after its samples',
			'line 3: lines of \'a\' are not together',
			'line 2: second sample for a{x="1"}',
			'line 1: unknown type \'gauges\'',
			'line 1: invalid escape \'\\t\' in label value',
			'line 1: duplicate label \'x\'',
			'line 1: unterminated label value',
		], [
			parse_error('a 1\na{x="1" 2\n'),
			parse_error('a up\n'),
			parse_error('# TYPE a gauge\n# TYPE a gauge\n'),
			parse_error('a 1\n# TYPE a gauge\n'),
			parse_error('a 1\nb 1\na{x="1"} 2\n'),
			parse_error('a{x="1"} 1\na{x="1"} 2\n'),
			parse_error('# TYPE a gauges\n'),
			parse_error('a{x="\\t"} 1\n'),
			parse_error('a{x="1",x="2"} 1\n'),
			parse_error('a{x="1} 1\n'),
		]);
	});

	it('treats the same labels in another order as the same series', () => {
		assert.match(regex(/second sample/), parse_error('a{x="1",y="2"} 1\na{y="2",x="1"} 1\n'));
	});
});

// Families with distinct names, of any type, with labels of any printable text.
const FAMILIES = gen.map(gen.array(gen.record({
	type: gen.elements('counter', 'gauge', 'untyped'),
	help: gen.optional(gen.ascii({ min_len: 1, max_len: 12 })),
	samples: gen.array(gen.tuple(gen.ascii({ min_len: 0, max_len: 8 }), gen.int(-1000, 1000)), { min_len: 1, max_len: 3 }),
}), { min_len: 0, max_len: 4 }), (fams) => {
	let i = 0;
	return map(fams, (f) => ({ ...f, name: `m${i++}` }));
});

describe('exposition: properties', () => {
	prop('parses back what it renders, to the same text', FAMILIES, (fams) => {
		let out = exposition.recorder();

		for (let f in fams) {
			let sample = out[f.type](f.name, f.help);
			let n = 0;
			for (let s in f.samples)
				sample({ i: n++, v: s[0] }, s[1]);
		}

		let text = exposition.render(out.families());
		let res = exposition.parse(text);

		assert.match(true, res.ok, res.details);
		assert.match(text, exposition.render(res.data));
	});

	prop('renders a label value that parses back unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (v) => {
		let res = exposition.parse(text_of((out) => out.gauge('g')({ v }, 1)));

		assert.match(v, res.data[0].samples[0].labels[0][1]);
	});
});
