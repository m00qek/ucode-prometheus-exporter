'use strict';

import { describe, it, prop, gen, assert, contains, regex } from 'utest';
import * as exposition from 'prometheus_exporter.exposition';

function text_of(fill) {
	let out = exposition.recorder();
	fill(out);
	return exposition.render(out.families());
}

function lines(text) {
	return text == '' ? [] : split(rtrim(text, '\n'), '\n');
}

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

describe('exposition.recorder, refusing what Prometheus refuses a scrape for', () => {
	// What a recorder stopped with: the error it threw, and its invalid().
	function refused(fill) {
		let out = exposition.recorder();
		let thrown = null;

		try {
			fill(out);
		} catch (e) {
			thrown = e.message;
		}

		return [ thrown, out.invalid() ];
	}

	it('stops at a label value that is not valid UTF-8, saying the family and the label', () => {
		assert.match([ exposition.INVALID, { family: 'wifi_ssid', label: 'ssid', why: 'its value is not valid UTF-8' } ],
			refused((out) => out.gauge('wifi_ssid')({ ssid: 'caf\xe9' }, 1)));
	});

	it('stops at HELP text that is not valid UTF-8', () => {
		assert.match([ exposition.INVALID, { family: 'h', label: null, why: 'its HELP text is not valid UTF-8' } ],
			refused((out) => out.gauge('h', 'caf\xe9')(null, 1)));
	});

	it('stops at two label names that are one once sanitized, in a sample or in labels()', () => {
		let why = "labels 'if-name' and 'if_name' are both 'if_name' once sanitized";

		assert.match([ exposition.INVALID, { family: 'x', label: 'if_name', why } ],
			refused((out) => out.gauge('x')({ 'if-name': '1', if_name: '2' }, 1)));
		assert.match([ exposition.INVALID, { family: null, label: 'if_name', why } ],
			refused((out) => out.labels({ 'if-name': '1', if_name: '2' })));
	});

	// Written as it is, it was a line of its own: raw_xeth0 up 1.
	it('stops at a string where the labels go that labels() did not make, or anything but an object', () => {
		assert.match([ exposition.INVALID, { family: 'raw_x', label: null, why: 'labels must be an object, or what out.labels() made, not a string of its own' } ],
			refused((out) => out.gauge('raw_x')('eth0 up', 1)));
		assert.match('labels must be an object, or what out.labels() made, not int',
			refused((out) => out.gauge('raw_x')(5, 1))[1].why);
	});

	it('takes what labels() made, UTF-8 and all, and an empty string', () => {
		assert.match([ '# TYPE w gauge', 'w{ssid="café"} 1', 'w 2' ], lines(text_of((out) => {
			let l = out.labels({ ssid: 'café' });

			out.gauge('w')(l, 1)('', 2);
		})));
	});

	it('stops every sample after the first refused, though the collector caught it', () => {
		let out = exposition.recorder();
		let g = out.gauge('g');
		let thrown = 0;

		for (let l in [ { s: '\xff' }, { s: 'fine' }, null ])
			try { g(l, 1); } catch (e) { thrown++; }

		assert.match([ 3, 'g', null ], [ thrown, out.invalid().family, out.over() ]);
	});
});

describe('exposition.pack', () => {
	it('gives the families\' names and types, and their text as render() writes it', () => {
		let rec = exposition.recorder();

		rec.gauge('a', 'A.')({ x: '1' }, 1)({ x: '2' }, 2);
		rec.counter('b_total')(null, 0);

		let packed = exposition.pack(rec.families());

		assert.match([ { name: 'a', type: 'gauge' }, { name: 'b_total', type: 'counter' } ], packed.families);
		assert.match(exposition.render(rec.families()), packed.text);
	});

	it('leaves out zero counters with omit, and a family left without samples', () => {
		let rec = exposition.recorder();

		rec.counter('z_total')(null, 0);
		rec.counter('c_total')({ i: '1' }, 0)({ i: '2' }, 5);
		assert.match('# TYPE c_total counter\nc_total{i="2"} 5\n', exposition.pack(rec.families(), true).text);
	});

	prop('writes what render() would, with omit or without',
		gen.tuple(gen.array(gen.int(0, 3), { min_len: 0, max_len: 6 }), gen.bool()), (t) => {
			let rec = exposition.recorder();
			let c = rec.counter('n_total');

			for (let i, v in t[0])
				c({ i }, v);
			assert.match(exposition.render(rec.families(), { omit_zero_counters: t[1] }), exposition.pack(rec.families(), t[1]).text);
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

	// merge() takes a family only one recorder has as it is, and copies one
	// that two have: the text must be one recorder's, and no input changed.
	prop('writes what one recorder of every sample would, and leaves its input as it was',
		gen.array(gen.tuple(gen.int(0, 2), gen.elements('a', 'b', 'c'), gen.int(0, 9)), { max_len: 12 }), (rows) => {
			let recs = [ exposition.recorder(), exposition.recorder(), exposition.recorder() ];
			let one = exposition.recorder();

			for (let i, r in rows) {
				recs[r[0]].counter(r[1], 'h')({ i }, r[2]);
				one.counter(r[1], 'h')({ i }, r[2]);
			}

			let lists = map(recs, (r) => r.families());
			let before = map(lists, (l) => exposition.render(l));
			let merged = exposition.merge(lists);

			// one recorder writes each family's samples in the order recorded;
			// merge() writes them by recorder, so compare them sorted.
			let sorted = (text) => sort(split(text, '\n'));
			assert.match(sorted(exposition.render(one.families())), sorted(exposition.render(merged.families)));
			// The families in the order they first appear, recorder by recorder.
			let order = [];
			for (let k = 0; k < 3; k++)
				for (let r in rows)
					if (r[0] == k && !(r[1] in order))
						push(order, r[1]);

			assert.match(order, map(merged.families, (f) => f.name));
			assert.match(before, map(lists, (l) => exposition.render(l)));
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

	it('writes HELP text that parse() reads back, backslashes before n included', () => {
		for (let help in [ '\\n', 'a\\\\nb', 'x\ny\\', '\\' ]) {
			let res = exposition.parse(text_of((out) => out.gauge('h', help)(null, 1)));
			assert.match(help, res.data[0].help);
		}
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

	// Label sets are written whole and escaped only when a value needs it:
	// values with quotes, backslashes and newlines, alone or not, by
	// labels() or not, must still read back as they were.
	prop('renders label sets that parse back unchanged, made once or per sample',
		gen.array(gen.string({ charset: 'a"\\\n{}=, ', min_len: 0, max_len: 6 }), { min_len: 1, max_len: 3 }), (vals) => {
			let out = exposition.recorder();
			let labels = {};

			for (let i, v in vals)
				labels[`l${i}`] = v;

			out.gauge('g')(labels, 1);
			out.gauge('h')(out.labels(labels), 2);

			let res = exposition.parse(exposition.render(out.families()));
			assert.match(true, res.ok, res.details);
			for (let fam in res.data)
				assert.match(vals, map(fam.samples[0].labels, (p) => p[1]));
		});

	prop('renders a label value that parses back unchanged', gen.ascii({ min_len: 0, max_len: 24 }), (v) => {
		let res = exposition.parse(text_of((out) => out.gauge('g')({ v }, 1)));

		assert.match(v, res.data[0].samples[0].labels[0][1]);
	});
});
