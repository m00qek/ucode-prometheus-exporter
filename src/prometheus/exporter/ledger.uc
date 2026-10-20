/**
 * The ledger: what a uhttpd instance's scrapes leave for the next, in its state.
 *
 * @module prometheus_exporter_ledger
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as breaker from 'prometheus.exporter.breaker';

/**
 * A collector's entry in the ledger; an absent field is its default.
 *
 * @typedef {{
 *   d: ?float,
 *   n: ?int,
 *   late: ?int,
 *   f: ?int,
 *   q: ?int,
 *   cd: ?int,
 *   why: ?string,
 *   fails: ?Object<string, int>,
 *   to: ?int,
 *   qn: ?int,
 *   dl: ?int
 * }} LedgerEntry
 */

/**
 * The ledger, as its JSON holds it: c is each collector's entry by id.
 *
 * @typedef {{ v: int, scrapes: int, auth_failures: ?int, k: ?float, c: Object<string, LedgerEntry> }} Ledger
 */

/**
 * What changed of a collector's breaker, as record() and killed() tell it.
 *
 * @typedef {{ name: string, tripped: boolean, closed: boolean, cooldown: ?int, why: ?string }} BreakerEvent
 */

/**
 * What the ledger counts, as counters() gives it, for the exporter's own collector.
 *
 * @typedef {{
 *   scrapes: int,
 *   auth_failures: int,
 *   collectors: Object<string, { failures: Object<string, int>, timeouts: int, quarantines: int, deadline_skips: int }>
 * }} LedgerCounters
 */

/**
 * What the ledger says of a collector, as report() gives it.
 *
 * @typedef {{ estimate: ?float, quarantined: boolean, reason: ?string, retry_in: ?int, late: ?int }} LedgerReport
 */

/**
 * The ledger's name in the state.
 *
 * @type {string}
 */
export const NAME = 'scrape';

/**
 * The ledger's version, its `v`.
 *
 * @type {int}
 */
export const VERSION = 1;

/**
 * The scrapes after which the deadline leaving a collector out is old news.
 *
 * @type {int}
 */
export const RECENT = 10;

/**
 * The most error codes a collector's failures are counted by; any other is counted as OTHER.
 *
 * @type {int}
 */
export const REASONS_MAX = 8;

/**
 * What a failure is counted as past REASONS_MAX codes, or with a code that is not one (CODE).
 *
 * @type {string}
 */
export const OTHER = 'OTHER';

/**
 * What a failure's code must be to be counted by it: an uppercase word, of at most CODE_MAX.
 *
 * @type {RegExp}
 */
export const CODE = /^[A-Z][A-Z0-9_]*$/;

/**
 * The most characters of a code the ledger counts failures by (CODE).
 *
 * @type {int}
 */
export const CODE_MAX = 64;

const WHY_MAX = 200;

/**
 * The weight of the last run in a duration's moving average.
 *
 * @type {float}
 */
export const ALPHA = 0.25;

/**
 * What a collector's estimate is made of itself each time the deadline leaves it out.
 *
 * @type {float}
 */
export const DEADLINE_DECAY = 0.75;

/**
 * The seconds a sample's writing is reckoned to take before the instance has measured it.
 *
 * @type {float}
 */
export const SAMPLE_SECONDS = 0.00005;

/**
 * A ledger with nothing in it.
 *
 * @returns {Ledger} { v: VERSION, scrapes: 0, k: null, c: {} }.
 */
export function empty() {
	return { v: VERSION, scrapes: 0, k: null, c: {} };
};

/**
 * The ledger of `text`: empty when there is none, or it is not one.
 *
 * @param {?string} text the ledger's JSON, as the state holds it.
 * @returns {Ledger} the ledger.
 */
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

/**
 * The ledger's JSON, as the state keeps it.
 *
 * @param {Ledger} ledger the ledger.
 * @param {?int} max the most bytes it may take; null for no limit.
 * @returns {string} its JSON.
 */
export function serialize(ledger, max) {
	let text = sprintf('%J', ledger);

	if (max == null || length(text) <= max)
		return text;

	let c = {};

	for (let id, e in ledger.c) {
		c[id] = { ...e };
		delete c[id].why;
		delete c[id].fails;
	}

	return sprintf('%J', { ...ledger, c });
};

/**
 * The number of the scrape that would start now.
 *
 * @param {Ledger} ledger the ledger.
 * @returns {int} the scrape's number.
 */
export function number(ledger) {
	return ledger.scrapes + 1;
};

/**
 * The seconds collector `id` is expected to take, or null before it ran.
 *
 * @param {Ledger} ledger the ledger.
 * @param {string} id the collector's module name.
 * @returns {?float} the seconds.
 */
export function estimate(ledger, id) {
	return ledger.c[id]?.d;
};

/**
 * The seconds the reply of a scrape of `samples` samples is expected to take to write.
 *
 * @param {Ledger} ledger the ledger.
 * @param {int} samples the reply's samples.
 * @returns {float} the seconds.
 */
export function writing(ledger, samples) {
	return samples * (ledger.k ?? SAMPLE_SECONDS);
};

/**
 * The samples collector `id` wrote last.
 *
 * @param {Ledger} ledger the ledger.
 * @param {string} id the collector's module name.
 * @returns {int} the samples; 0 before it ran.
 */
export function samples(ledger, id) {
	return ledger.c[id]?.n ?? 0;
};

function order_key(last, unknown, estimate, i) {
	return sprintf('%d%06d%025.12f%06d', last, unknown, estimate, i);
}

/**
 * `collectors` in the order a scrape runs them: fastest first, never-run ones by `rank`.
 *
 * @param {Ledger} ledger the ledger.
 * @param {Collector[]} collectors the collectors to order.
 * @param {?function(Collector): boolean} last which run after every other.
 * @param {?function(Collector): int} rank the rank of one never run.
 * @returns {Collector[]} the collectors, in that order.
 */
export function order(ledger, collectors, last, rank) {
	let places = [];
	let by_key = {};

	for (let i, c in collectors) {
		let e = ledger.c[c.id]?.d;
		let k = order_key((last && last(c)) ? 1 : 0, (e != null) ? 0 : (rank ? rank(c) : 1), e ?? 0, i);

		push(places, k);
		by_key[k] = c;
	}

	let out = [];

	for (let k in sort(places))
		push(out, by_key[k]);

	return out;
};

function average(old, value) {
	return (old == null) ? value : old + ALPHA * (value - old);
}

/**
 * What a run means to its collector's breaker, and why: [ outcome, why ].
 *
 * @param {Run} run the run.
 * @returns {(string|?string)[]} [ 'ok', 'failed', 'trip' or 'neutral', and why, or null ].
 */
export function outcome_of(run) {
	let res = run.result;

	if (run.skipped != null)
		return [ 'neutral', null ];
	if (res?.error == errors.COLLECTOR_CANCELLED || res?.error == errors.COLLECTOR_KILLED)
		return [ 'trip', Result.describe(res) ];
	if (run.budget != null && run.duration > run.budget)
		return [ 'trip', sprintf('%s (took %.2f s, over its budget of %d s)', errors.COLLECTOR_OVERRUN, run.duration, run.budget) ];
	if (res?.error == errors.COMMAND_TIMEOUT)
		return [ 'trip', Result.describe(res) ];
	if (res?.error == errors.SCRAPE_DEADLINE || (res?.error == errors.SAMPLE_LIMIT && res?.data?.scrape))
		return [ 'neutral', null ];
	if (!res?.ok)
		return [ 'failed', Result.describe(res) ];

	return [ 'ok', null ];
};

function count_failure(e, code) {
	if (type(code) != 'string' || length(code) > CODE_MAX || !match(code, CODE))
		code = OTHER;

	let fails = { ...(e.fails ?? {}) };
	let key = (fails[code] != null || length(fails) < REASONS_MAX) ? code : OTHER;

	fails[key] = (fails[key] ?? 0) + 1;
	e.fails = fails;
}

function update(e, r, n, events) {
	let res = r.result;
	let code = res?.error;
	let skipped = r.skipped;

	if (skipped == null) {
		e.d = (e.d == null) ? r.duration : e.d + ALPHA * (r.duration - e.d);
		e.n = r.samples ?? 0;

		if (code != null && code != errors.SCRAPE_DEADLINE)
			count_failure(e, code);
		if (code == errors.COMMAND_TIMEOUT)
			e.to = (e.to ?? 0) + 1;
	}

	if (code == errors.SCRAPE_DEADLINE) {
		e.late = n;
		e.dl = (e.dl ?? 0) + 1;
	}
	if (skipped == 'deadline' && e.d != null)
		e.d *= DEADLINE_DECAY;

	let change = null;

	if (skipped == null && code == null && res?.ok && (r.budget == null || r.duration <= r.budget)) {
		delete e.f;
		if (e.q != null)
			change = breaker.apply(e, 'ok', n, null);
	} else {
		let o = outcome_of(r);

		change = breaker.apply(e, o[0], n, (o[1] != null) ? substr(o[1], 0, WHY_MAX) : null);
	}

	if (change == null)
		return e;
	if (events)
		push(events, { name: r.name, tripped: change == 'tripped', closed: change == 'closed', cooldown: e.cd, why: e.why });
	if (change == 'tripped')
		e.qn = (e.qn ?? 0) + 1;

	return e;
}

/**
 * The ledger `ledger` with scrape `runs` recorded, as the scrape counts it.
 *
 * @param {Ledger} ledger the ledger as it is.
 * @param {Run[]} runs the scrape's runs.
 * @param {?{ seconds: float, samples: int }} written what writing the reply took, or null.
 * @param {string[]} ids the installed collectors' module names.
 * @param {?BreakerEvent[]} events what gets what changed, or null.
 * @returns {Ledger} the new ledger; `ledger` is left as it is.
 */
export function record(ledger, runs, written, ids, events) {
	let n = number(ledger);
	let had = ledger.c;
	let c = {};

	for (let id in ids) {
		let e = had[id];

		if (e != null)
			c[id] = e;
	}

	for (let r in runs)
		c[r.id] = update({ ...(c[r.id] ?? {}) }, r, n, events);

	let k = ledger.k;

	if (written?.samples > 0)
		k = average(k, written.seconds / (written.samples * 1.0));

	return { ...ledger, scrapes: n, k, c };
};

/**
 * The ledger `ledger` with collector `id` killed with the scrape process it ran in.
 *
 * @param {Ledger} ledger the ledger as it is.
 * @param {string} id the collector's module name.
 * @param {string} name the collector's name.
 * @param {string} why what happened, for the breaker's why.
 * @param {?BreakerEvent[]} events what gets what changed, or null.
 * @returns {Ledger} the new ledger; `ledger` is left as it is.
 */
export function killed(ledger, id, name, why, events) {
	let n = number(ledger) - 1;
	let e = { ...(ledger.c[id] ?? {}) };
	let res = Result.err(errors.COLLECTOR_KILLED, why);

	count_failure(e, errors.COLLECTOR_KILLED);

	let b = breaker.after(e, 'trip', n, substr(Result.describe(res), 0, WHY_MAX));

	b.entry.qn = (b.entry.qn ?? 0) + 1;
	if (events)
		push(events, { name, tripped: true, closed: false, cooldown: b.entry.cd, why: b.entry.why });

	return { ...ledger, c: { ...ledger.c, [id]: b.entry } };
};

/**
 * The ledger `ledger` with one more request that basic auth refused.
 *
 * @param {Ledger} ledger the ledger as it is.
 * @returns {Ledger} the new ledger.
 */
export function auth_failure(ledger) {
	return { ...ledger, auth_failures: (ledger.auth_failures ?? 0) + 1 };
};

function counted(e) {
	return { failures: e.fails ?? {}, timeouts: e.to ?? 0, quarantines: e.qn ?? 0, deadline_skips: e.dl ?? 0 };
}

/**
 * What the ledger counts, for the exporter's own collector.
 *
 * @param {Ledger} ledger the ledger.
 * @returns {LedgerCounters} the counters, each collector's by id.
 */
export function counters(ledger) {
	let out = { scrapes: ledger.scrapes, auth_failures: ledger.auth_failures ?? 0, collectors: {} };

	for (let id, e in ledger.c)
		out.collectors[id] = counted(e);

	return out;
};

/**
 * What the ledger would count with `runs` recorded: counters(record(ledger, runs, null, ids)).
 *
 * @param {Ledger} ledger the ledger.
 * @param {Run[]} runs the scrape's runs so far.
 * @param {string[]} ids the installed collectors' module names.
 * @returns {LedgerCounters} the counters, each collector's by id.
 */
export function counters_with(ledger, runs, ids) {
	let n = number(ledger);
	let had = ledger.c;
	let installed = {};
	let after = {};
	let counting = [];
	let out = { scrapes: n, auth_failures: ledger.auth_failures ?? 0, collectors: {} };

	for (let id in ids)
		installed[id] = true;

	for (let r in runs) {
		if (r.result?.error == null && (r.skipped != null || r.budget == null || !(r.duration > r.budget)))
			continue;

		let e = after[r.id] ?? (installed[r.id] ? had[r.id] : null);

		after[r.id] = update({ ...(e ?? {}) }, r, n, null);
		push(counting, r.id);
	}

	for (let id in ids)
		if (had[id] != null)
			out.collectors[id] = counted(after[id] ?? had[id]);
	for (let id in counting)
		out.collectors[id] ??= counted(after[id]);
	for (let r in runs)
		out.collectors[r.id] ??= { failures: {}, timeouts: 0, quarantines: 0, deadline_skips: 0 };

	return out;
};

/**
 * Collector `id`'s breaker at scrape number `m`: 'closed', 'open' or 'trial'.
 *
 * @param {Ledger} ledger the ledger.
 * @param {string} id the collector's module name.
 * @param {int} m the scrape's number.
 * @returns {string} the phase.
 */
export function phase(ledger, id, m) {
	return breaker.phase(ledger.c[id], m);
};

/**
 * The result of a collector its breaker keeps out of scrape number `m`.
 *
 * @param {Ledger} ledger the ledger.
 * @param {string} id the collector's module name.
 * @param {int} m the scrape's number.
 * @returns {Result} COLLECTOR_QUARANTINED, saying why and when it is tried again.
 */
export function quarantined(ledger, id, m) {
	let e = ledger.c[id];
	let k = breaker.left(e, m);

	return Result.err(errors.COLLECTOR_QUARANTINED,
		sprintf('not run: %s; tried again %s', e.why ?? 'its breaker is open', (k <= 1) ? 'at the next scrape' : `in ${k} scrapes`));
};

/**
 * What the ledger says of collector `id`, as of the instance's last scrape, or null.
 *
 * @param {Ledger} ledger the ledger.
 * @param {string} id the collector's module name.
 * @returns {?LedgerReport} the report, or null.
 */
export function report(ledger, id) {
	let e = ledger.c[id];

	if (e == null)
		return null;

	let held = (e.q != null);

	return {
		estimate: e.d,
		quarantined: held,
		reason: held ? e.why : null,
		retry_in: held ? breaker.left(e, number(ledger)) + 1 : null,
		late: (e.late != null) ? ledger.scrapes - e.late : null,
	};
};
