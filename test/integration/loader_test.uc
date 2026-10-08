'use strict';

// prometheus_exporter.loader for real: the collectors of the source tree
// compiled as ucode compiles them, and what that leaves open.

import { describe, it, assert } from 'utest';
import * as loader from 'prometheus_exporter.loader';
import * as fs from 'fs';

const SOURCES = 'src/prometheus_exporter/collectors';

function descriptors() {
	return length(fs.lsdir('/proc/self/fd') ?? []);
}

describe('loader.import_modules', () => {
	it('compiles what the collectors share once: a source kept open per module, not per collector', () => {
		let ids = loader.discover(fs, SOURCES);

		gc();

		let before = descriptors();
		let mods = loader.import_modules(ids);
		let opened = descriptors() - before;

		assert.match([], filter(ids, (id) => !loader.validate(id, mods[id]).ok));
		// One per collector, and one per module behind the collector API.
		assert.match(true, opened <= length(ids) + 10, `${opened} descriptors for ${length(ids)} collectors`);
	});
});
