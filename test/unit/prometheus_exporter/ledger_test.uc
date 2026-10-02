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

	it('keeps the duration of a collector left out, and the scrape that left it out at the deadline', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 1, 5) ], null, [ 'a' ]);

		l = ledger.record(l, [ skipped('a') ], null, [ 'a' ]);
		assert.match({ d: 1, n: 5, late: 2 }, l.c.a);
	});

	it('averages a collector cut at the deadline with what it ran, and says it was late', () => {
		let l = ledger.record(ledger.empty(), [ ran('a', 2, 0, Result.err('SCRAPE_DEADLINE', 'killed')) ], null, [ 'a' ]);

		assert.match({ d: 2, n: 0, late: 1 }, l.c.a);
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

	it('fits the state with a hundred collectors that failed in every way they can', () => {
		let ids = map([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ], (i) => `hostapd_ubus_stations_${i}`);
		let l = ledger.empty();

		for (let i = 0; i < 4; i++)
			l = ledger.record(l, map(ids, (id) => run_with(id, 123.456789, Result.err('SOURCE_INVALID', sprintf('%0300d', 0)))), null, ids);

		// Ten in a tenth of the state's room.
		assert.match(true, length(ledger.serialize(l)) * 10 < 32768, `${length(ledger.serialize(l))}`);
	});
});
