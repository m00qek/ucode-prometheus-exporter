'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as breaker from 'prometheus.exporter.breaker';

// Entry `e` after `outcomes`, one per scrape from scrape `n`: each scrape the
// breaker keeps the collector out of does not run it, and takes no outcome.
// [ entry, [ scrape, phase, outcome taken or null ] per scrape ].
function run(outcomes, e, n) {
	let trace = [];

	n ??= 1;
	for (let o in outcomes) {
		let p = breaker.phase(e, n);
		let taken = (p == 'open') ? null : o;

		if (taken != null)
			e = breaker.after(e, taken, n, `why ${n}`).entry;
		push(trace, [ n, p, taken ]);
		n++;
	}

	return [ e, trace ];
}

describe('breaker.after', () => {
	it('trips after FAILURES failures in a row, for a scrape', () => {
		let e = null;

		for (let n = 1; n < breaker.FAILURES; n++) {
			let b = breaker.after(e, 'failed', n, 'SOURCE_INVALID');

			assert.match([ false, n ], [ b.tripped, b.entry.f ]);
			e = b.entry;
		}

		let b = breaker.after(e, 'failed', breaker.FAILURES, 'SOURCE_INVALID');

		assert.match({ tripped: true, entry: { q: breaker.FAILURES + 1, cd: 1, why: 'SOURCE_INVALID' } }, { tripped: b.tripped, entry: b.entry });
	});

	it('starts counting again after a success', () => {
		let e = run([ 'failed', 'failed', 'ok', 'failed', 'failed' ], null)[0];

		assert.match({ f: 2 }, e);
	});

	it('trips at once on a program killed at its timeout, or a budget overrun', () => {
		let b = breaker.after({ d: 1 }, 'trip', 7, 'COMMAND_TIMEOUT (nft: still running after 5 s, killed)');

		assert.match({ tripped: true, closed: false, entry: { d: 1, q: 8, cd: 1, why: 'COMMAND_TIMEOUT (nft: still running after 5 s, killed)' } }, b);
	});

	it('closes on a trial that succeeds, and forgets why it tripped', () => {
		let b = breaker.after({ d: 1, q: 8, cd: 4, why: 'x' }, 'ok', 9);

		assert.match({ tripped: false, closed: true, entry: { d: 1 } }, b);
	});

	it('trips again, for twice the cool-down, on a trial that fails in any way', () => {
		assert.match([ { q: 17, cd: 8, why: 'y' }, { q: 17, cd: 8, why: 'y' } ],
			map([ 'failed', 'trip' ], (o) => breaker.after({ q: 8, cd: 4, why: 'x' }, o, 9, 'y').entry));
	});

	it('changes nothing on a run neither good nor bad', () => {
		let e = { d: 2, f: 1, q: 5, cd: 2, why: 'x' };

		assert.match({ tripped: false, closed: false, entry: e }, breaker.after(e, 'neutral', 6));
	});
});

describe('breaker.phase', () => {
	it('keeps the collector out for its cool-down, then gives it a trial', () => {
		let e = breaker.after(null, 'trip', 10, 'x').entry;

		assert.match([ 'closed', 'open', 'trial' ], [ breaker.phase(null, 10), breaker.phase(e, 11), breaker.phase(e, 12) ]);
		assert.match([ 1, 0, null ], [ breaker.left(e, 11), breaker.left(e, 12), breaker.left(null, 12) ]);
	});

	it('doubles the cool-down of every failed trial, up to COOLDOWN_MAX', () => {
		let trace = run(map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 ], () => 'trip'), null)[1];
		// The scrapes it ran in.
		let tried = map(filter(trace, (t) => t[2] != null), (t) => t[0]);

		assert.match([ 1, 3, 6, 11 ], slice(tried, 0, 4));

		let e = null, cds = [];
		for (let n = 1; length(cds) < 9; n++)
			if (breaker.phase(e, n) != 'open') {
				e = breaker.after(e, 'trip', n, 'x').entry;
				push(cds, e.cd);
			}
		assert.match([ 1, 2, 4, 8, 16, 32, 32, 32, 32 ], cds);
	});
});

describe('breaker, over any scrapes', () => {
	const OUTCOMES = gen.array(gen.elements('ok', 'failed', 'trip', 'neutral'), { min_len: 1, max_len: 120 });

	prop('quarantines for 1, 2, 4… scrapes, never more than COOLDOWN_MAX, and then always tries again', OUTCOMES, (outcomes) => {
		let e = null;
		let open_run = 0;

		for (let n = 1; n <= length(outcomes); n++) {
			let p = breaker.phase(e, n);

			if (p == 'open') {
				open_run++;
				assert.match(true, open_run <= breaker.COOLDOWN_MAX);
				continue;
			}

			open_run = 0;

			let b = breaker.after(e, outcomes[n - 1], n, 'why');

			e = b.entry;
			if (e.q != null) {
				assert.match(true, e.cd in [ 1, 2, 4, 8, 16, 32 ], `${e.cd}`);
				assert.match(true, e.q - n <= e.cd);
			} else {
				assert.match([ null, null, true ], [ e.cd, e.why, (e.f ?? 0) < breaker.FAILURES ]);
			}
		}
	});

	prop('closes only on a success, and trips only on a failure or a trip', OUTCOMES, (outcomes) => {
		let e = null;

		for (let n = 1; n <= length(outcomes); n++) {
			if (breaker.phase(e, n) == 'open')
				continue;

			let o = outcomes[n - 1];
			let b = breaker.after(e, o, n, 'why');

			if (b.closed)
				assert.match('ok', o);
			if (b.tripped)
				assert.match(true, o in [ 'failed', 'trip' ]);
			e = b.entry;
		}
	});

	prop('never trips a collector that only succeeds or does not run', gen.array(gen.elements('ok', 'neutral'), { min_len: 1, max_len: 60 }), (outcomes) => {
		assert.match(null, run(outcomes, null)[0].q);
	});
});

describe('breaker.apply', () => {
	// The ledger's, on an entry of its own: it must make of the entry what
	// after() makes of a copy, and say what after() says.
	prop('changes an entry as after() changes a copy of it, and leaves after()\'s alone',
		gen.tuple(gen.array(gen.elements('ok', 'failed', 'trip', 'neutral'), { min_len: 0, max_len: 30 }), gen.elements('ok', 'failed', 'trip', 'neutral')),
		(t) => {
			let e = run(t[0], null)[0] ?? {};
			let before = sprintf('%J', e);
			let b = breaker.after(e, t[1], 40, 'why');
			let own = { ...e };
			let change = breaker.apply(own, t[1], 40, 'why');

			assert.match([ before, b.entry, b.tripped ? 'tripped' : (b.closed ? 'closed' : null) ], [ sprintf('%J', e), own, change ]);
		});
});
