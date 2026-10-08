/**
 * The ledger: what a uhttpd instance's scrapes leave for the next, in its state
 * (prometheus_exporter.state, as NAME), lost when the service restarts. A
 * scrape reads it when it starts, to run the collectors fastest first and to
 * know which of them its deadline has time for; and records its own when it is
 * done, under the state's lock (update), on the ledger as it is then: scrapes
 * that ran at once each add what they saw.
 *
 * It is JSON: { v, scrapes, auth_failures, k, c: { <collector id>: entry } }
 *   v        VERSION; a ledger of another is read as empty
 *   scrapes  the scrapes the instance answered, this one's number less one
 *   auth_failures  the requests basic auth refused (401)
 *   k        seconds per sample of writing a scrape's reply (merging and
 *            rendering), an exponential moving average
 *   entry    { d: its duration, a moving average, which each scrape that
 *              leaves it out at the deadline makes DEADLINE_DECAY of itself;
 *              n: samples it wrote last;
 *              late: the scrape that last left it out at the deadline;
 *              f, q, cd, why: its breaker's (prometheus_exporter.breaker);
 *              counted since the instance started: fails, { code: its failures
 *              with it }; to, its programs killed at their timeout; qn, the
 *              times its breaker tripped; dl, the times the deadline left it
 *              out or cut it }
 *
 * The averages weigh the last run by ALPHA.
 *
 * @module prometheus_exporter_ledger
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as breaker from 'prometheus_exporter.breaker';

/**
 * A collector's entry in the ledger, its fields as the module's top comment
 * says: d, n and late of its runs; f, q, cd and why its breaker's
 * (prometheus_exporter.breaker); fails, to, qn and dl counted since the
 * instance started. An absent field is its default.
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
 * The ledger, as its JSON holds it: { v, scrapes, auth_failures, k, c },
 * c each collector's entry by id.
 *
 * @typedef {{ v: int, scrapes: int, auth_failures: ?int, k: ?float, c: Object<string, LedgerEntry> }} Ledger
 */

/**
 * What changed of a collector's breaker, as record() and killed() tell it:
 * the collector's name, whether its breaker tripped or closed, its
 * cool-down in scrapes and what tripped it.
 *
 * @typedef {{ name: string, tripped: boolean, closed: boolean, cooldown: ?int, why: ?string }} BreakerEvent
 */

/**
 * What the ledger counts, as counters() gives it, for the exporter's own
 * collector: each collector's by id (by name once the scrape names them).
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
 * The scrapes after which the deadline leaving a collector out is old news to
 * check and the ubus object's status.
 *
 * @type {int}
 */
export const RECENT = 10;

/**
 * The most error codes a collector's failures are counted by; any other is
 * counted as OTHER. The codes are errors.uc's, a dozen that a collector can
 * fail with, but a collector of another's may make its own.
 *
 * @type {int}
 */
export const REASONS_MAX = 8;

/**
 * What a failure is counted as past REASONS_MAX codes.
 *
 * @type {string}
 */
export const OTHER = 'OTHER';

// The most of a breaker's why the ledger keeps.
const WHY_MAX = 200;

/**
 * The weight of the last run in a duration's moving average. A collector
 * takes much the same time scrape after scrape, but for what it reads that
 * grows or shrinks (the conntrack table): at 0.25 a spike of one scrape is
 * half gone after two more, and a lasting change nine tenths there after
 * eight.
 *
 * @type {float}
 */
export const ALPHA = 0.25;

/**
 * What a collector's estimate is made of itself each time the deadline leaves
 * it out (record): it is not run then, so not timed, and one slow run would
 * keep it out for the instance's life. Three quarters: an estimate of twice
 * the time the deadline leaves is tried again after 3 scrapes it was left
 * out of, one of ten times after 9. A run, in time or cut at the deadline,
 * measures it again.
 *
 * @type {float}
 */
export const DEADLINE_DECAY = 0.75;

/**
 * The seconds a sample's writing is reckoned to take before the instance has
 * measured it: a 500-MIPS MIPS core's, 50 µs, about thirty times the 1.6 µs
 * the devenv takes (52 ms for the 33,000 samples of the benchmark's large
 * world), so a reply is never reckoned shorter than it is on the slowest
 * router.
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
 * @returns {string} its JSON.
 */
export function serialize(ledger) {
	return sprintf('%J', ledger);
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
 * The seconds the reply of a scrape of `samples` samples is expected to take
 * to write.
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

// sort()'s order of [ last, never run, estimate, index ]: by each, as
// numbers, which a difference of seconds, a fraction, would not give it.
function by_keys(a, b) {
	for (let i = 0; i < 4; i++)
		if (a[i] != b[i])
			return (a[i] < b[i]) ? -1 : 1;

	return 0;
}

/**
 * `collectors` in the order a scrape runs them: fastest first; one never run,
 * which may be slow, after those the ledger knows, so that it cannot take
 * their time, and among those, by `rank(c)` (1 without it): the scrape
 * ranks the exporter's own collectors before the others, and of each, one
 * that declares itself heavy (meta.cost) after the rest; in their order among
 * equals; those `last(c)` says, after every other.
 *
 * A declared cost orders and does nothing else: the deadline leaves a
 * collector out only by what the ledger measured, so that one that declares
 * itself heavy is still run, and timed, rather than left out for good.
 *
 * @param {Ledger} ledger the ledger.
 * @param {Collector[]} collectors the collectors to order.
 * @param {?function(Collector): boolean} last which run after every other.
 * @param {?function(Collector): int} rank the rank of one never run.
 * @returns {Collector[]} the collectors, in that order.
 */
export function order(ledger, collectors, last, rank) {
	let keyed = map(collectors, function(c, i) {
		let known = estimate(ledger, c.id) != null;
		let unknown = known ? 0 : (rank ? rank(c) : 1);

		return [ (last && last(c)) ? 1 : 0, unknown, estimate(ledger, c.id) ?? 0, i, c ];
	});

	return map(sort(keyed, by_keys), (x) => x[4]);
};

function average(old, value) {
	return (old == null) ? value : old + ALPHA * (value - old);
}

/**
 * What a run means to its collector's breaker (prometheus_exporter.breaker),
 * and why: [ outcome, why ].
 *
 * @param {Run} run the run.
 * @returns {(string|?string)[]} [ 'ok', 'failed', 'trip' or 'neutral', and
 *   why, or null ].
 */
export function outcome_of(run) {
	let res = run.result;

	if (run.skipped != null)
		return [ 'neutral', null ];
	if (res?.error in [ errors.COLLECTOR_CANCELLED, errors.COLLECTOR_KILLED ])
		return [ 'trip', Result.describe(res) ];
	if (run.budget != null && run.duration > run.budget)
		return [ 'trip', sprintf('%s (took %.2f s, over its budget of %d s)', errors.COLLECTOR_OVERRUN, run.duration, run.budget) ];
	if (res?.error == errors.COMMAND_TIMEOUT)
		return [ 'trip', Result.describe(res) ];
	if (res?.error == errors.SCRAPE_DEADLINE)
		return [ 'neutral', null ];
	if (!res?.ok)
		return [ 'failed', Result.describe(res) ];

	return [ 'ok', null ];
};

// One failure of collector `id` counted in `e` (an entry): by `code`, or as
// OTHER past REASONS_MAX codes.
function count_failure(e, code) {
	let fails = { ...(e.fails ?? {}) };
	let key = (code in keys(fails) || length(fails) < REASONS_MAX) ? code : OTHER;

	fails[key] = (fails[key] ?? 0) + 1;
	e.fails = fails;
}

/**
 * The ledger `ledger` with scrape `runs` recorded, as the scrape counts it: one
 * more scrape; for each collector that ran, its duration and samples, and
 * what its run makes of its breaker; for each the deadline left out or cut,
 * that it did, and of one it left out, its estimate made DEADLINE_DECAY of
 * itself; and the seconds per sample the reply took to write (`written`:
 * { seconds, samples }). `ids` are the installed collectors': any other's
 * entry goes. A run is scrape.run_one's or not_run's: { id, name, result,
 * duration, samples, budget, skipped }. `events`, when given, gets what
 * changed of the breakers: { name, tripped, closed, cooldown, why }.
 *
 * @param {Ledger} ledger the ledger as it is.
 * @param {Run[]} runs the scrape's runs.
 * @param {?{ seconds: float, samples: int }} written what writing the reply
 *   took, or null.
 * @param {string[]} ids the installed collectors' module names.
 * @param {?BreakerEvent[]} events what gets what changed, or null.
 * @returns {Ledger} the new ledger; `ledger` is left as it is.
 */
export function record(ledger, runs, written, ids, events) {
	let n = number(ledger);
	let c = {};

	for (let id in ids)
		if (ledger.c[id] != null)
			c[id] = ledger.c[id];

	for (let r in runs) {
		let e = { ...(c[r.id] ?? {}) };
		let code = r.result?.error;

		if (r.skipped == null) {
			e.d = average(e.d, r.duration);
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
		if (r.skipped == 'deadline' && e.d != null)
			e.d *= DEADLINE_DECAY;

		let o = outcome_of(r);
		let b = breaker.after(e, o[0], n, (o[1] != null) ? substr(o[1], 0, WHY_MAX) : null);

		if (events && (b.tripped || b.closed))
			push(events, { name: r.name, tripped: b.tripped, closed: b.closed, cooldown: b.entry.cd, why: b.entry.why });
		if (b.tripped)
			b.entry.qn = (b.entry.qn ?? 0) + 1;

		c[r.id] = b.entry;
	}

	let k = ledger.k;

	if (written?.samples > 0)
		k = average(k, written.seconds / (written.samples * 1.0));

	return { ...ledger, scrapes: n, k, c };
};

/**
 * The ledger `ledger` with collector `id` (named `name`) killed with the scrape
 * process it ran in, `why`: a failure, COLLECTOR_KILLED, which trips its
 * breaker as of the scrape that died, which never recorded itself: its
 * cool-down begins with the next scrape. `events` gets what changed of the
 * breaker, as record's.
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

/**
 * What the ledger counts, for the exporter's own collector: { scrapes,
 * auth_failures, collectors: { <id>: { failures: { code: n }, timeouts,
 * quarantines, deadline_skips } } }.
 *
 * @param {Ledger} ledger the ledger.
 * @returns {LedgerCounters} the counters, each collector's by id.
 */
export function counters(ledger) {
	let out = { scrapes: ledger.scrapes, auth_failures: ledger.auth_failures ?? 0, collectors: {} };

	for (let id, e in ledger.c)
		out.collectors[id] = { failures: e.fails ?? {}, timeouts: e.to ?? 0, quarantines: e.qn ?? 0, deadline_skips: e.dl ?? 0 };

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
 * @returns {Result} COLLECTOR_QUARANTINED, saying why and when it is tried
 *   again.
 */
export function quarantined(ledger, id, m) {
	let e = ledger.c[id];
	let k = breaker.left(e, m);

	return Result.err(errors.COLLECTOR_QUARANTINED,
		sprintf('not run: %s; tried again %s', e.why ?? 'its breaker is open', (k <= 1) ? 'at the next scrape' : `in ${k} scrapes`));
};

/**
 * What the ledger says of collector `id`, for check and the ubus object, as of
 * the instance's last scrape: { estimate, quarantined, reason, retry_in,
 * late }. retry_in: the scrapes until its trial, 1 for the next; late: the
 * scrapes since the deadline last left it out, 0 for the last. Null for a
 * collector the ledger has nothing of.
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
