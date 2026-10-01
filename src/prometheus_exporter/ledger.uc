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
//              late: the scrape that last left it out at the deadline }
//
// The averages weigh the last run by ALPHA.

// The ledger's name in the state.
export const NAME = 'scrape';

export const VERSION = 1;

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

// The ledger `l` with scrape `runs` recorded, as the scrape counts it: one
// more scrape; for each collector that ran, its duration and samples; for
// each the deadline left out or cut, that it did; and the seconds per sample
// the reply took to write (`written`: { seconds, samples }). `ids` are the
// installed collectors': any other's entry goes. A run is scrape.run_one's or
// not_run's: { id, result, duration, samples, skipped }.
export function record(l, runs, written, ids) {
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

		if (r.result?.error == 'SCRAPE_DEADLINE')
			e.late = n;

		c[r.id] = e;
	}

	let k = l.k;

	if (written?.samples > 0)
		k = average(k, written.seconds / (written.samples * 1.0));

	return { ...l, scrapes: n, k, c };
};
