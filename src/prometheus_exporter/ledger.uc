'use strict';

// The ledger: what a uhttpd instance's scrapes leave for the next, in its state
// (prometheus_exporter.state, as NAME), lost when the service restarts. A
// scrape reads it when it starts, to run the collectors fastest first and to
// know which of them its deadline has time for; and records its own when it is
// done, under the state's lock (update), on the ledger as it is then: scrapes
// that ran at once each add what they saw.
//
// It is JSON: { v, scrapes, k, c: { <collector id>: entry } }
//   v        VERSION; a ledger of another is read as empty
//   scrapes  the scrapes the instance answered, this one's number less one
//   k        seconds per sample of writing a scrape's reply (merging and
//            rendering), an exponential moving average
//   entry    { d: its duration, a moving average; n: samples it wrote last;
//              late: the scrape that last left it out at the deadline;
//              f, q, cd, why: its breaker's (prometheus_exporter.breaker) }
//
// The averages weigh the last run by ALPHA.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as breaker from 'prometheus_exporter.breaker';

// The ledger's name in the state.
export const NAME = 'scrape';

export const VERSION = 1;

// The scrapes after which the deadline leaving a collector out is old news to
// check and the ubus object's status.
export const RECENT = 10;

// The most of a breaker's why the ledger keeps.
const WHY_MAX = 200;

// The weight of the last run in a duration's moving average. A collector
// takes much the same time scrape after scrape, but for what it reads that
// grows or shrinks (the conntrack table): at 0.25 a spike of one scrape is
// half gone after two more, and a lasting change nine tenths there after
// eight.
export const ALPHA = 0.25;

// The seconds a sample's writing is reckoned to take before the instance has
// measured it: a 500-MIPS MIPS core's, 50 µs, about thirty times the 1.6 µs
// the devenv takes (52 ms for the 33,000 samples of the benchmark's large
// world), so a reply is never reckoned shorter than it is on the slowest
// router.
export const SAMPLE_SECONDS = 0.00005;

// A ledger with nothing in it.
export function empty() {
	return { v: VERSION, scrapes: 0, k: null, c: {} };
};

// The ledger of `text`: empty when there is none, or it is not one.
export function parse(text) {
	let l = null;

	if (type(text) == 'string') {
		try {
			l = json(text);
		} catch (e) {
			l = null;
		}
	}

	if (type(l) != 'object' || l.v !== VERSION || type(l.c) != 'object' || type(l.scrapes) != 'int')
		return empty();

	return l;
};

export function serialize(l) {
	return sprintf('%J', l);
};

// The number of the scrape that would start now.
export function number(l) {
	return l.scrapes + 1;
};

// The seconds collector `id` is expected to take, or null before it ran.
export function estimate(l, id) {
	return l.c[id]?.d;
};

// The seconds the reply of a scrape of `samples` samples is expected to take
// to write.
export function writing(l, samples) {
	return samples * (l.k ?? SAMPLE_SECONDS);
};

// The samples collector `id` wrote last.
export function samples(l, id) {
	return l.c[id]?.n ?? 0;
};

// sort()'s order of [ last, estimate, index ]: by each, as numbers, which a
// difference of seconds, a fraction, would not give it.
function by_keys(a, b) {
	for (let i = 0; i < 3; i++)
		if (a[i] != b[i])
			return (a[i] < b[i]) ? -1 : 1;

	return 0;
}

// `collectors` in the order a scrape runs them: fastest first, one never run
// (as fast as can be) before the rest, and in their order among equals; those
// `last(c)` says, after every other.
export function order(l, collectors, last) {
	let keyed = map(collectors, (c, i) => [ (last && last(c)) ? 1 : 0, estimate(l, c.id) ?? 0, i, c ]);

	return map(sort(keyed, by_keys), (x) => x[3]);
};

function average(old, value) {
	return (old == null) ? value : old + ALPHA * (value - old);
}

// What a run means to its collector's breaker (prometheus_exporter.breaker),
// and why: [ outcome, why ].
export function outcome_of(r) {
	let res = r.result;

	if (r.skipped != null)
		return [ 'neutral', null ];
	if (r.budget != null && r.duration > r.budget)
		return [ 'trip', sprintf('%s (took %.2f s, over its budget of %d s)', errors.COLLECTOR_OVERRUN, r.duration, r.budget) ];
	if (res?.error == errors.COMMAND_TIMEOUT)
		return [ 'trip', Result.describe(res) ];
	if (res?.error == errors.SCRAPE_DEADLINE)
		return [ 'neutral', null ];
	if (!res?.ok)
		return [ 'failed', Result.describe(res) ];

	return [ 'ok', null ];
};

// The ledger `l` with scrape `runs` recorded, as the scrape counts it: one
// more scrape; for each collector that ran, its duration and samples, and
// what its run makes of its breaker; for each the deadline left out or cut,
// that it did; and the seconds per sample the reply took to write (`written`:
// { seconds, samples }). `ids` are the installed collectors': any other's
// entry goes. A run is scrape.run_one's or not_run's: { id, name, result,
// duration, samples, budget, skipped }. `events`, when given, gets what
// changed of the breakers: { name, tripped, closed, cooldown, why }.
export function record(l, runs, written, ids, events) {
	let n = number(l);
	let c = {};

	for (let id in ids)
		if (l.c[id] != null)
			c[id] = l.c[id];

	for (let r in runs) {
		let e = { ...(c[r.id] ?? {}) };

		if (r.skipped == null) {
			e.d = average(e.d, r.duration);
			e.n = r.samples ?? 0;
		}

		if (r.result?.error == errors.SCRAPE_DEADLINE)
			e.late = n;

		let o = outcome_of(r);
		let b = breaker.after(e, o[0], n, (o[1] != null) ? substr(o[1], 0, WHY_MAX) : null);

		if (events && (b.tripped || b.closed))
			push(events, { name: r.name, tripped: b.tripped, closed: b.closed, cooldown: b.entry.cd, why: b.entry.why });

		c[r.id] = b.entry;
	}

	let k = l.k;

	if (written?.samples > 0)
		k = average(k, written.seconds / (written.samples * 1.0));

	return { ...l, scrapes: n, k, c };
};

// Collector `id`'s breaker at scrape number `m`: 'closed', 'open' or 'trial'.
export function phase(l, id, m) {
	return breaker.phase(l.c[id], m);
};

// The result of a collector its breaker keeps out of scrape number `m`.
export function quarantined(l, id, m) {
	let e = l.c[id];
	let k = breaker.left(e, m);

	return Result.err(errors.COLLECTOR_QUARANTINED,
		sprintf('not run: %s; tried again %s', e.why ?? 'its breaker is open', (k <= 1) ? 'at the next scrape' : `in ${k} scrapes`));
};

// What the ledger says of collector `id`, for check and the ubus object, as of
// the instance's last scrape: { estimate, quarantined, reason, retry_in,
// late }. retry_in: the scrapes until its trial, 1 for the next; late: the
// scrapes since the deadline last left it out, 0 for the last. Null for a
// collector the ledger has nothing of.
export function report(l, id) {
	let e = l.c[id];

	if (e == null)
		return null;

	let held = (e.q != null);

	return {
		estimate: e.d,
		quarantined: held,
		reason: held ? e.why : null,
		retry_in: held ? breaker.left(e, number(l)) + 1 : null,
		late: (e.late != null) ? l.scrapes - e.late : null,
	};
};
