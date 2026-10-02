'use strict';

// prometheus_exporter.probe for real: modules loaded in forked child
// processes, one that does not load in time stopped with its process.

import { describe, it, assert } from 'utest';
import * as probe from 'prometheus_exporter.probe';
import * as loader from 'prometheus_exporter.loader';
import { seconds } from 'prometheus_exporter.deadline';
import * as fs from 'fs';

function now() {
	return seconds(clock(true));
}

describe('probe.probe', () => {
	it('loads each module in a child, and stops one that does not load in time', () => {
		let t = now();
		let res = probe.probe([ 'a', 'stuck', 'broken', 'b' ], function(id) {
			if (id == 'stuck')
				while (true)
					;
			if (id == 'broken')
				die('Unable to compile module\nmore');
			return {};
		}, 1);
		let took = now() - t;

		assert.match({ a: true, stuck: false, broken: false, b: true }, { a: res.a.ok, stuck: res.stuck.ok, broken: res.broken.ok, b: res.b.ok });
		assert.match([ true, 'still loading after 1 s: stopped' ], [ res.stuck.hung, res.stuck.error ]);
		assert.match([ false, 'Unable to compile module' ], [ res.broken.hung, res.broken.error ]);
		assert.match(true, took < 2.5, `took ${took} s`);
	});

	it('says a module whose loading ended its process did not load', () => {
		let res = probe.probe([ 'quits', 'b' ], (id) => (id == 'quits') ? exit(1) : {}, 1);

		assert.match([ false, true ], [ res.quits.ok, res.b.ok ]);
	});

	it('loads the real collectors', () => {
		let ids = loader.discover(fs, 'src/prometheus_exporter/collectors');
		let res = probe.probe(ids, loader.import_module);

		assert.match([], filter(ids, (id) => !res[id]?.ok));
	});
});
