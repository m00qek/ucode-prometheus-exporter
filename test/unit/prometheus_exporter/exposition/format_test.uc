'use strict';

import { describe, it, prop, gen, assert, regex } from 'utest';
import * as format from 'prometheus_exporter.exposition.format';

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

	prop('keeps integers exact, as numbers and as procfs text', gen.int(-2147483648, 2147483647), (n) => {
		assert.match([ '' + n, '' + n ], [ format.format_value(n), format.format_value(` ${n}\n`) ]);
	});
});
