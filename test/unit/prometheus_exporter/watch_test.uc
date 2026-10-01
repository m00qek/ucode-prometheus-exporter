'use strict';

import { describe, it, assert } from 'utest';
import * as watch from 'prometheus_exporter.watch';

// A sys whose paths appear at these rounds ({ path: round }), and that records
// what it slept, sent and logged.
function system(appear, reloads) {
	let round = 0;
	let out = { slept: [], sent: 0, logs: [] };

	out.sys = {
		exists: (p) => p in keys(appear) && round >= appear[p],
		sleep: function(ms) { push(out.slept, ms); round++; },
		reload: function() { out.sent++; return reloads ?? true; },
		log: (m) => push(out.logs, m),
	};

	return out;
}

describe('watch.run', () => {
	it('names the event the init script reloads on', () => {
		assert.match('prometheus-exporter.path', watch.EVENT);
	});

	it('looks every few seconds while nothing is there, and sends nothing', () => {
		let s = system({});

		assert.match([ { found: [], reloaded: false }, { found: [], reloaded: false } ], watch.run(s.sys, [ '/var/lib/unbound' ], 2));
		assert.match([ [ watch.INTERVAL_MS, watch.INTERVAL_MS ], 0, [] ], [ s.slept, s.sent, s.logs ]);
	});

	it('sends the event once a path is there, then waits for the reload', () => {
		let s = system({ '/var/lib/unbound': 2 });

		assert.match([
			{ found: [], reloaded: false },
			{ found: [], reloaded: false },
			{ found: [ '/var/lib/unbound' ], reloaded: true },
		], watch.run(s.sys, [ '/var/lib/unbound', '/tmp/bmx7' ], 3));
		assert.match([ [ watch.INTERVAL_MS, watch.INTERVAL_MS, watch.QUIET_MS ], 1 ], [ s.slept, s.sent ]);
		assert.match([ '/var/lib/unbound is there now: reloading to mount it' ], s.logs);
	});

	it('looks at once: a path may be there before it starts', () => {
		let s = system({ '/a': 0, '/b': 0 });

		assert.match([ { found: [ '/a', '/b' ], reloaded: true } ], watch.run(s.sys, [ '/a', '/b' ], 1));
		assert.match([ '/a, /b are there now: reloading to mount them' ], s.logs);
	});

	it('asks again later when procd does not take the event', () => {
		let s = system({ '/a': 0 }, false);

		watch.run(s.sys, [ '/a' ], 2);
		assert.match([ 2, [ watch.QUIET_MS, watch.QUIET_MS ] ], [ s.sent, s.slept ]);
		assert.match(`cannot send procd ${watch.EVENT}; trying again in 60s`, s.logs[1]);
	});
});
