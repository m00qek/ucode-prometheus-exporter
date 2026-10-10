'use strict';

// prometheus.exporter.probe for real: modules loaded in forked child
// processes, one that does not load in time stopped with its process.

import { describe, it, assert } from 'utest';
import * as probe from 'prometheus.exporter.probe';
import * as loader from 'prometheus.exporter.loader';
import { seconds } from 'prometheus.exporter.deadline';
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

	// uloop takes SIGTERM while the probe waits: what procd sends an
	// instance still loading its collectors, in an upgrade of several
	// packages. Each module not loaded then says so, and its signal.
	it('says which modules it did not load when this process was asked to stop', () => {
		let me = fs.readlink('/proc/self');
		let res = probe.probe([ 'a', 'b', 'c' ], function(id) {
			if (id == 'b')
				system([ 'kill', '-TERM', me ]);
			sleep(300);
			return {};
		}, 5, null, true);

		assert.match([ true, null ], [ res.a.ok, res.a.stopped ]);
		assert.match([ false, 15, 'not loaded: this process was asked to stop (signal 15)' ], [ res.b.ok, res.b.stopped, res.b.error ]);
		assert.match([ false, 15 ], [ res.c.ok, res.c.stopped ]);
	});

	it('loads the real collectors', () => {
		let ids = loader.discover(fs, 'src/prometheus/collectors');
		let res = probe.probe(ids, loader.import_module);

		assert.match([], filter(ids, (id) => !res[id]?.ok));
	});
});
