'use strict';

import { describe, it, assert, regex } from 'utest';
import { parse } from 'prometheus.exporter.exposition.parse';

function parse_error(text) {
	let res = parse(text);
	return res.ok ? null : res.details;
}

describe('exposition.parse', () => {
	it('reads families, labels with escapes, timestamps, and histogram series', () => {
		let res = parse(
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

	// Prometheus refuses a whole scrape with either: a Latin-1 SSID in a
	// *.prom file would cost every collector's samples.
	it('refuses a label value or HELP text that is not valid UTF-8, and takes one that is', () => {
		assert.match([ 'line 2: label \'ssid\': its value is not valid UTF-8', 'line 1: HELP for \'a\' is not valid UTF-8' ],
			[ parse_error('# TYPE a gauge\na{ssid="caf\xe9"} 1\n'), parse_error('# HELP a caf\xe9\na 1\n') ]);
		assert.match([ true, 'café', 'Ünïcödé ✓' ], (function() {
			let res = parse('# HELP a Ünïcödé ✓\na{ssid="café"} 1\n# a comment of \xff, which nothing reads\n');

			return [ res.ok, res.data[0].samples[0].labels[0][1], res.data[0].help ];
		})());
	});

	// ucode's regexes stop at a NUL: what follows one must not be read past.
	it('refuses a NUL byte anywhere', () => {
		assert.match([ 'line 2: holds a NUL byte', 'line 1: holds a NUL byte', 'line 1: holds a NUL byte', 'line 1: holds a NUL byte' ], [
			parse_error('a 1\na{x="1\0"} 2\n'),
			parse_error('a\0{x="1"} 2\nevil 1\n'),
			parse_error('# HELP a x\0\xe9\na 1\n'),
			parse_error('a 1\0 garbage\n'),
		]);
	});

	it('treats the same labels in another order as the same series', () => {
		assert.match(regex(/second sample/), parse_error('a{x="1",y="2"} 1\na{y="2",x="1"} 1\n'));
	});
});
