'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as query from 'node_exporter.query';

function urlencode(s) {
	return replace(s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf('%%%02X', ord(c)));
}

describe('query.parse', () => {
	it('reads collect=, collect[]= (plain or encoded) and exclude[]=', () => {
		assert.match({ collect: [ 'cpu', 'ltq-dsl', 'wifi' ], exclude: [ 'netdev' ] },
			query.parse('collect=cpu&collect[]=ltq-dsl&collect%5B%5D=wifi&exclude[]=netdev&other=1'));
	});

	it('drops repeats and pairs without a value', () => {
		assert.match({ collect: [ 'cpu' ], exclude: [] }, query.parse('collect=cpu&collect=cpu&collect&=x'));
	});

	it('is empty for no query', () => {
		assert.match({ collect: [], exclude: [] }, query.parse(null));
	});

	prop('decodes any encoded name', gen.array(gen.ascii({ min_len: 1, max_len: 10 }), { min_len: 0, max_len: 5 }), (names) => {
		let q = join('&', map(names, (n) => 'collect[]=' + urlencode(n)));
		assert.match(uniq(names), query.parse(q).collect);
	});
});
