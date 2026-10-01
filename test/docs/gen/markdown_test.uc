'use strict';

import { describe, it, assert } from 'utest';
import * as md from 'docs_gen.markdown';

describe('docs_gen.markdown.text', () => {
	it('escapes markup outside code spans, and leaves the spans as they are', () => {
		assert.match('a \\| b &lt;stat&gt; node\\_exporter `a|b_<c>` 2 \\* 3',
			md.text('a | b <stat> node_exporter `a|b_<c>` 2 * 3'));
	});

	it('takes null as nothing', () => {
		assert.match('', md.text(null));
	});
});

describe('docs_gen.markdown.code', () => {
	it('fences with more backticks than the text holds', () => {
		assert.match([ '`x`', '``a`b``', '`` `x ``' ], [ md.code('x'), md.code('a`b'), md.code('`x') ]);
	});
});

describe('docs_gen.markdown.table', () => {
	it('writes the head, the rule and a row each, an empty cell as a dash', () => {
		assert.match('| A | B |\n| :--- | :--- |\n| 1 | — |\n| — | 2 |',
			md.table([ 'A', 'B' ], [ [ '1', '' ], [ null, '2' ] ]));
	});
});

describe('docs_gen.markdown.heading', () => {
	it('gives a heading its anchor', () => {
		assert.match([ '## `ltq-dsl` {#ltq-dsl}', '# Title' ], [ md.heading(2, '`ltq-dsl`', md.anchor('ltq-dsl')), md.heading(1, 'Title') ]);
	});
});
