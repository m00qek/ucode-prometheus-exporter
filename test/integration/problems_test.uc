'use strict';

// What the exporter finds wrong with a value, by its code, is said twice: in English
// by the core (prometheus_exporter.config.problems), and in the user's language by
// LuCI, whose sentence of each code is in the PROBLEMS table of its shared module.
// Every code has both, and LuCI has a sentence of no code the core does not have.

import { describe, it, assert } from 'utest';
import { readfile } from 'fs';
import * as config from 'prometheus_exporter.config';

const SHARED = 'luci/htdocs/luci-static/resources/prometheus-exporter.js';

// The codes of LuCI's PROBLEMS table: the keys of `const PROBLEMS = { ... };`, one a line.
function luci_codes(text) {
	let start = index(text, '\nconst PROBLEMS = {\n');
	let end = (start < 0) ? -1 : index(substr(text, start), '\n};\n');

	if (start < 0 || end < 0)
		die(`${SHARED} has no PROBLEMS table`);

	let codes = [];

	for (let l in split(substr(text, start, end), '\n')) {
		let m = match(l, /^\t([A-Z_]+):/);

		if (m)
			push(codes, m[1]);
	}

	return codes;
}

describe('problems', () => {
	it('has a sentence in LuCI for every code the core says in English, and for no other', () => {
		let codes = luci_codes(readfile(SHARED));

		assert.match(length(uniq(codes)), length(codes));
		assert.match(sort(keys(config.PROBLEMS)), sort(codes));
	});

	it('says every code in English', () => {
		for (let code, c in config.PROBLEMS) {
			let args = {};

			for (let a in c.args)
				args[a] = 1;

			assert.match('string', type(config.english(config.problem(code, args))), code);
		}
	});
});
