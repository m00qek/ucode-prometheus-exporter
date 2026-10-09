'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as ledger from 'prometheus_exporter.ledger';
import * as Result from 'prometheus_exporter.result';

function ran(id, duration, samples, result) {
	return { id, duration, samples: samples ?? 0, result: result ?? Result.ok() };
}

function skipped(id) {
	return { id, duration: 0, samples: 0, result: Result.err('SCRAPE_DEADLINE', 'not run'), skipped: 'deadline' };
}

function ids(list) {
	return map(list, (c) => c.id);
}

describe('ledger.parse', () => {
	it('reads back what serialize wrote', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 0.5, 3) ], { seconds: 0.01, samples: 100 }, [ 'a' ]);

		assert.match(l, ledger.parse(ledger.serialize(l)));
	});

	it('is empty for no ledger, one that is not JSON, or not this version\'s', () => {
		for (let text in [ null, '', '{', '[]', '{"v":2,"scrapes":1,"c":{}}', '{"v":1,"scrapes":"x","c":{}}' ])
			assert.match(ledger.empty(), ledger.parse(text), text);
	});
});

describe('ledger.record', () => {
	it('counts the scrape, and keeps each collector\'s duration and samples', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 0.5, 3), ran('b', 2, 40) ], null, [ 'a', 'b' ]);

		assert.match({ scrapes: 1, c: { a: { d: 0.5, n: 3 }, b: { d: 2, n: 40 } } }, { scrapes: l.scrapes, c: l.c });
	});

	it('averages durations, the last one weighed by ALPHA', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 1) ], null, [ 'a' ]);

		l = ledger.record(l, [ ran('a', 3) ], null, [ 'a' ]);
		assert.match(1 + ledger.ALPHA * 2, ledger.estimate(l, 'a'));
	});

	it('decays the estimate of a collector left out by DEADLINE_DECAY, and keeps the scrape that left it out at the deadline', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 1, 5) ], null, [ 'a' ]);

		l = ledger.record(l, [ skipped('a') ], null, [ 'a' ]);
		assert.match({ d: ledger.DEADLINE_DECAY, n: 5, late: 2, dl: 1 }, l.c.a);
		assert.match(0.75, ledger.DEADLINE_DECAY);
	});

	// One slow run must not keep a collector out for the instance's life.
	it('brings a collector left out at every scrape back within the deadline, and measures it again once it runs', () => {
		let l = ledger.record(ledger.empty(), [ ran('slow', 8) ], null, [ 'slow' ]);
		let skips = 0;

		while (ledger.estimate(l, 'slow') >= 1 && skips < 100) {
			l = ledger.record(l, [ skipped('slow') ], null, [ 'slow' ]);
			skips++;
		}

		assert.match(8, skips, '8 s to under 1 s: 0.75 to the 8th is 0.1');
		l = ledger.record(l, [ ran('slow', 0.2) ], null, [ 'slow' ]);
		let decayed = 8 * 0.75 ** 8;
		let d = ledger.estimate(l, 'slow') - (decayed + ledger.ALPHA * (0.2 - decayed));

		assert.match(true, d < 1e-9 && d > -1e-9);
	});

	it('leaves the estimate of a collector quarantined, not left out at the deadline, as it was', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 1) ], null, [ 'a' ]);

		l = ledger.record(l, [ { id: 'a', duration: 0, samples: 0, result: Result.err('COLLECTOR_QUARANTINED', 'x'), skipped: 'quarantine' } ], null, [ 'a' ]);
		assert.match(1, ledger.estimate(l, 'a'));
	});

	it('averages a collector cut at the deadline with what it ran, and says it was late', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 2, 0, Result.err('SCRAPE_DEADLINE', 'killed')) ], null, [ 'a' ]);

		assert.match({ d: 2, n: 0, late: 1, dl: 1 }, l.c.a);
	});

	it('drops what it kept of a collector no longer installed', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 1), ran('gone', 1) ], null, [ 'a', 'gone' ]);

		assert.match([ 'a' ], keys(ledger.record(l, [], null, [ 'a' ]).c));
	});

	it('averages the seconds a sample of the reply takes to write', () => {
		let l = ledger.record(ledger.empty(), [], { seconds: 0.2, samples: 1000 }, []);

		assert.match(0.0002, l.k);
		assert.match(0.0002 + ledger.ALPHA * (0.0001 - 0.0002), ledger.record(l, [], { seconds: 0.1, samples: 1000 }, []).k);
		assert.match(0.0002, ledger.record(l, [], { seconds: 0.1, samples: 0 }, []).k);
	});

	prop('keeps an average between the fewest and the most seconds a collector took',
		gen.array(gen.int(0, 100000), { min_len: 1, max_len: 12 }), (ms) => {
			let l = ledger.empty();

			for (let m in ms)
				l = ledger.record(l, [ ran('a', m / 1000.0) ], null, [ 'a' ]);

			let d = ledger.estimate(l, 'a');

			assert.match([ true, true, length(ms) ], [ d >= min(...ms) / 1000.0 - 1e-9, d <= max(...ms) / 1000.0 + 1e-9, l.scrapes ]);
		});
});

describe('ledger.writing', () => {
	it('reckons a sample at SAMPLE_SECONDS until a scrape measured it', () => {
		let l = ledger.empty();

		assert.match([ 100 * ledger.SAMPLE_SECONDS, 0.02 ],
			[ ledger.writing(l, 100), ledger.writing(ledger.record(l, [], { seconds: 0.1, samples: 500 }, []), 100) ]);
	});
});

describe('ledger.order', () => {
	const A = { id: 'a' }, B = { id: 'b' }, C = { id: 'c' }, D = { id: 'd' };

	function with_durations(d) {
		return ledger.record(ledger.empty(), map(keys(d), (id) => ran(id, d[id])), null, keys(d));
	}

	it('runs the fastest first, one never run after the rest, equals in the order given', () => {
		let l = with_durations({ a: 3, b: 0.5, c: 0.5 });

		assert.match([ 'b', 'c', 'a', 'd' ], ids(ledger.order(l, [ A, B, C, D ])));
		assert.match([ 'd', 'a' ], ids(ledger.order(ledger.empty(), [ D, A ])));
		assert.match([ 'c', 'b', 'a' ], ids(ledger.order(l, [ C, B, A ])));
	});

	it('runs those it is told to after every other', () => {
		assert.match([ 'a', 'b' ], ids(ledger.order(with_durations({ a: 3, b: 0.5 }), [ A, B ], (c) => c.id == 'b')));
	});

	it('orders those the ledger has not timed by their rank, until it has', () => {
		let rank = (c) => c.rank;
		let H = { id: 'h', rank: 2 }, L = { id: 'l', rank: 1 };

		assert.match([ 'l', 'd', 'h' ], ids(ledger.order(ledger.empty(), [ H, L, { id: 'd', rank: 1 } ], null, rank)));
		assert.match([ 'a', 'l', 'h' ], ids(ledger.order(with_durations({ a: 9 }), [ H, L, A ], null, rank)));
		assert.match([ 'h', 'l' ], ids(ledger.order(with_durations({ h: 0.1 }), [ H, L ], null, rank)));
	});

	prop('orders every collector once, by what each is expected to take',
		gen.array(gen.int(0, 5000), { min_len: 0, max_len: 8 }), (ms) => {
			let cs = map(ms, (m, i) => ({ id: `c${i}` }));
			let d = {};

			for (let i, m in ms)
				d[`c${i}`] = m / 1000.0;

			let l = with_durations(d);
			let got = ledger.order(l, cs);

			assert.match(sort(ids(cs)), sort(ids(got)));
			for (let i = 1; i < length(got); i++)
				assert.match(true, ledger.estimate(l, got[i - 1].id) <= ledger.estimate(l, got[i].id));
		});
});

describe('ledger, the breakers', () => {
	function run_with(id, duration, result, budget) {
		return { id, name: id, duration, samples: 1, result: result ?? Result.ok(), budget: budget ?? 5 };
	}

	it('tells what each run means to its breaker', () => {
		assert.match([
			[ 'ok', null ],
			[ 'ok', null ],
			[ 'failed', 'SOURCE_INVALID (x)' ],
			[ 'trip', 'COMMAND_TIMEOUT (nft: still running after 5 s, killed)' ],
			[ 'trip', 'COLLECTOR_OVERRUN (took 6.50 s, over its budget of 5 s)' ],
			[ 'neutral', null ],
			[ 'neutral', null ],
		], map([
			run_with('a', 1),
			run_with('a', 1, Result.none('no radios')),
			run_with('a', 1, Result.err('SOURCE_INVALID', 'x')),
			run_with('a', 5.2, Result.err('COMMAND_TIMEOUT', 'nft: still running after 5 s, killed'), 10),
			run_with('a', 6.5),
			run_with('a', 2, Result.err('SCRAPE_DEADLINE', 'killed')),
			skipped('a'),
		], ledger.outcome_of));
	});

	it('quarantines a collector that overran its budget, says so, and keeps it out until its trial', () => {
		let events = [];
		let l = ledger.record(ledger.empty(), [ run_with('slow', 7.25) ], null, [ 'slow' ], events);

		assert.match([ { name: 'slow', tripped: true, closed: false, cooldown: 1, why: 'COLLECTOR_OVERRUN (took 7.25 s, over its budget of 5 s)' } ], events);
		assert.match([ 'open', 'trial' ], [ ledger.phase(l, 'slow', 2), ledger.phase(l, 'slow', 3) ]);
		assert.match('COLLECTOR_QUARANTINED (not run: COLLECTOR_OVERRUN (took 7.25 s, over its budget of 5 s); tried again at the next scrape)',
			Result.describe(ledger.quarantined(l, 'slow', 2)));
		assert.match({ estimate: 7.25, quarantined: true, reason: 'COLLECTOR_OVERRUN (took 7.25 s, over its budget of 5 s)', retry_in: 2, late: null },
			ledger.report(l, 'slow'));
	});

	it('says in how many scrapes a longer quarantine ends', () => {
		let l = { ...ledger.empty(), scrapes: 20, c: { a: { q: 28, cd: 8, why: 'x' } } };

		assert.match([ 'COLLECTOR_QUARANTINED (not run: x; tried again in 8 scrapes)', 9 ],
			[ Result.describe(ledger.quarantined(l, 'a', 21)), ledger.report(l, 'a').retry_in ]);
	});

	it('closes a breaker whose trial succeeds, and says so', () => {
		let events = [];
		let l = { ...ledger.empty(), scrapes: 4, c: { a: { d: 1, q: 4, cd: 2, why: 'x' } } };

		l = ledger.record(l, [ run_with('a', 1) ], null, [ 'a' ], events);
		assert.match([ [ { name: 'a', tripped: false, closed: true, cooldown: null, why: null } ], 'closed' ], [ events, ledger.phase(l, 'a', 6) ]);
		assert.match({ estimate: 1.0, quarantined: false, reason: null, retry_in: null, late: null }, ledger.report(l, 'a'));
	});

	it('reports when the deadline last left a collector out, and nothing of a collector it never saw', () => {
		let l = ledger.record(ledger.empty(), [ skipped('a') ], null, [ 'a' ]);

		l = ledger.record(l, [], null, [ 'a' ]);
		assert.match([ 1, null ], [ ledger.report(l, 'a').late, ledger.report(l, 'b') ]);
	});

	// A collector's own code is any string it likes, kept in every scrape's
	// ledger: one of kilobytes once made the state refuse the ledger, which
	// then froze, a quarantine with it.
	it('counts a code that is not an uppercase word of at most 64 characters as OTHER', () => {
		let huge = sprintf('%05000d', 7);
		let l = ledger.empty();

		for (let code in [ 'X' + huge, 'lower', 'A-B', sprintf('A%064d', 0), 42, 'MY_OWN_CODE' ])
			l = ledger.record(l, [ run_with('a', 0.1, Result.err(code)) ], null, [ 'a' ]);

		assert.match({ OTHER: 5, MY_OWN_CODE: 1 }, l.c.a.fails);
		assert.match(true, length(ledger.serialize(l)) < 1000);
	});

	// Its length is counted, not matched as {0,63}, which musl compiles
	// into 56 kB the handler would hold: it counts what that takes.
	prop('counts by its code what an uppercase word of 1 to 64 characters, matched, is',
		gen.string({ min_len: 0, max_len: 70, charset: 'AZ09_a-' }), (code) => {
			let l = ledger.record(ledger.empty(), [ run_with('a', 0.1, Result.err(code)) ], null, [ 'a' ]);
			let word = match(code, /^[A-Z][A-Z0-9_]{0,63}$/) != null;

			assert.match(word ? { [code]: 1 } : { OTHER: 1 }, l.c.a.fails, code);
		});

	it('writes a ledger over `max` without breakers\' whys and failures by code, and keeps the rest', () => {
		let ids = map([ 1, 2, 3 ], (i) => `c${i}`);
		let l = ledger.record(ledger.empty(), map(ids, (id) => run_with(id, 2.5, Result.err('SOURCE_INVALID', sprintf('%0150d', 0)))), null, ids);
		let full = ledger.serialize(l);
		let slim = ledger.parse(ledger.serialize(l, length(full) - 1));

		assert.match(full, ledger.serialize(l, length(full)));
		assert.match([ { d: 2.5, n: 1, f: 1 }, null, null ], [ slim.c.c1, slim.c.c1.why, slim.c.c1.fails ]);
		assert.match(1, slim.scrapes);
	});

	it('fits the state with a hundred collectors that failed in every way they can', () => {
		let ids = map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ], (i) => `hostapd_ubus_stations_${i}`);
		let l = ledger.empty();

		for (let i = 0; i < 4; i++)
			l = ledger.record(l, map(ids, (id) => run_with(id, 123.456789, Result.err('SOURCE_INVALID', sprintf('%0300d', 0)))), null, ids);

		// Ten in a tenth of the state's room.
		assert.match(true, length(ledger.serialize(l)) * 10 < 32768, `${length(ledger.serialize(l))}`);
	});
});

describe('ledger, a collector stopped or killed', () => {
	function run_with(id, result, duration) {
		return { id, name: id, duration: duration ?? 0.1, samples: 0, result, budget: 5 };
	}

	it('trips the breaker of one stopped at its budget, or killed with its process, at once', () => {
		for (let code in [ 'COLLECTOR_CANCELLED', 'COLLECTOR_KILLED' ])
			assert.match([ 'trip', `${code} (why)` ], ledger.outcome_of(run_with('c', Result.err(code, 'why'))), code);
	});

	it('counts one over its samples, or writing another\'s family, as a failure', () => {
		for (let code in [ 'SAMPLE_LIMIT', 'FAMILY_CONFLICT' ])
			assert.match('failed', ledger.outcome_of(run_with('c', Result.err(code, 'why')))[0], code);
	});

	it('takes one stopped at the deadline as the deadline\'s, not the collector\'s', () => {
		assert.match('neutral', ledger.outcome_of(run_with('c', Result.err('SCRAPE_DEADLINE', 'stopped', { deadline: true }), 3))[0]);
	});

	it('quarantines a collector killed with its scrape process, and counts it', () => {
		let events = [];
		let l = ledger.killed(ledger.record(ledger.empty(), [ ran('a', 0.1) ], null, [ 'a' ]), 'a', 'a', 'it died', events);

		assert.match([ 'open', 'trial', { COLLECTOR_KILLED: 1 }, 1 ], [ ledger.phase(l, 'a', ledger.number(l)), ledger.phase(l, 'a', ledger.number(l) + 1), l.c.a.fails, l.c.a.qn ]);
		assert.match([ { name: 'a', tripped: true, closed: false, cooldown: 1, why: 'COLLECTOR_KILLED (it died)' } ], events);
		assert.match({ failures: { COLLECTOR_KILLED: 1 }, timeouts: 0, quarantines: 1, deadline_skips: 0 }, ledger.counters(l).collectors.a);
	});
});

describe('ledger.counters', () => {
	function run_with(id, result, extra) {
		return { id, name: id, duration: 0.1, samples: 1, result: result ?? Result.ok(), budget: 5, ...(extra ?? {}) };
	}

	it('counts each collector\'s failures by code, programs killed, quarantines and deadline skips, and the scrapes', () => {
		let runs = [
			run_with('a', Result.err('COMMAND_TIMEOUT', 'nft: still running after 5 s, killed')),
			run_with('b', Result.err('SOURCE_INVALID', 'x')),
			run_with('c', Result.err('SCRAPE_DEADLINE', 'not run'), { skipped: 'deadline', duration: 0 }),
			run_with('d', Result.none('no radios')),
		];
		let l = ledger.record(ledger.empty(), runs, null, [ 'a', 'b', 'c', 'd' ]);

		l = ledger.record(l, [ run_with('b', Result.err('SOURCE_UNREADABLE', 'y')) ], null, [ 'a', 'b', 'c', 'd' ]);

		assert.match({
			scrapes: 2, auth_failures: 0, collectors: {
				a: { failures: { COMMAND_TIMEOUT: 1 }, timeouts: 1, quarantines: 1, deadline_skips: 0 },
				b: { failures: { SOURCE_INVALID: 1, SOURCE_UNREADABLE: 1 }, timeouts: 0, quarantines: 0, deadline_skips: 0 },
				c: { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 1 },
				d: { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 0 },
			},
		}, ledger.counters(l));
	});

	it('counts the requests basic auth refused', () => {
		assert.match(2, ledger.counters(ledger.auth_failure(ledger.auth_failure(ledger.empty()))).auth_failures);
	});

	it('counts any code past REASONS_MAX as OTHER', () => {
		let l = ledger.empty();

		for (let i = 0; i < ledger.REASONS_MAX + 2; i++)
			l = ledger.record(l, [ run_with('a', Result.err(`CODE_${i}`)) ], null, [ 'a' ]);

		let f = ledger.counters(l).collectors.a.failures;

		assert.match([ ledger.REASONS_MAX + 1, 2 ], [ length(f), f[ledger.OTHER] ]);
	});

	prop('never lets a counter go down, scrape after scrape',
		gen.array(gen.elements('ok', 'failed', 'timeout', 'late', 'none'), { min_len: 1, max_len: 40 }), (kinds) => {
			let results = {
				ok: Result.ok(), none: Result.none('x'), failed: Result.err('SOURCE_INVALID'),
				timeout: Result.err('COMMAND_TIMEOUT'), late: Result.err('SCRAPE_DEADLINE'),
			};
			let l = ledger.empty();
			let before = ledger.counters(l);

			for (let k in kinds) {
				let m = ledger.number(l);
				let run = (ledger.phase(l, 'a', m) == 'open')
					? run_with('a', Result.err('COLLECTOR_QUARANTINED'), { skipped: 'quarantine', duration: 0 })
					: run_with('a', results[k]);

				l = ledger.record(l, [ run ], null, [ 'a' ]);

				let after = ledger.counters(l);
				let a = after.collectors.a, b = before.collectors.a ?? { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 0 };

				assert.match([ true, true, true, true ], [ after.scrapes == before.scrapes + 1, a.timeouts >= b.timeouts,
					a.quarantines >= b.quarantines, a.deadline_skips >= b.deadline_skips ]);
				for (let code, n in b.failures)
					assert.match(true, a.failures[code] >= n);
				before = after;
			}
		});
});
