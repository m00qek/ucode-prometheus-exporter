'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { match_line } from 'prometheus.exporter.line';

// Each case is one a ucode release reads apart from another: ^ and $ at each
// line or at the text's ends, . across a newline or not.
describe('line.match_line', () => {
	it('matches a text of one line as match() does', () => {
		assert.match([ 'abc' ], match_line('abc', /^[a-z]+$/));
		assert.match([ 'x=1', '1' ], match_line('x=1', /^x=(.*)$/));
		assert.match(null, match_line('ab1', /^[a-z]+$/));
	});

	it('matches nothing in a text of more lines, whatever ^, $ and . read a newline as', () => {
		for (let text in [ 'abc\n', '\nabc', 'abc\nd-e', 'd-e\nabc', 'a\nb' ])
			assert.match(null, match_line(text, /^[a-z]+$/), text);

		assert.match(null, match_line('x=1\n2', /^x=(.*)$/));
		assert.match(null, match_line('a\nb', /a.b/));
	});

	it('reads anything but null as match() does, and null as nothing', () => {
		assert.match([ '123' ], match_line(123, /^[0-9]+$/));
		assert.match(null, match_line(null, /^$/));
	});

	prop('takes what match() takes of a text without a newline', gen.string({ charset: 'ab-\n', min_len: 0, max_len: 8 }), (s) => {
		let want = (index(s, '\n') < 0) ? match(s, /^[ab]*$/) : null;

		assert.match(want, match_line(s, /^[ab]*$/), s);
	});
});
