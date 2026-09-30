'use strict';

import { describe, it, assert } from 'utest';
import * as errors from 'node_exporter.errors';

describe('errors', () => {
	it('spells every code as its own name', () => {
		for (let name, code in errors)
			assert.match(name, code);
	});
});
