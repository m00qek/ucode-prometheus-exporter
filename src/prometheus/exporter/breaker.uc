/**
 * A collector's circuit breaker, counted in scrapes of the instance.
 *
 * @module prometheus_exporter_breaker
 */

'use strict';

/**
 * What after() makes of an entry: the new entry, and whether the breaker tripped or closed.
 *
 * @typedef {{ entry: LedgerEntry, tripped: boolean, closed: boolean }} BreakerChange
 */

/** Failures in a row that trip a breaker. */
export const FAILURES = 3;

/** The most scrapes a quarantine lasts: 1, 2, 4, 8, 16, 32. */
export const COOLDOWN_MAX = 32;

/**
 * 'closed', 'open' (quarantined) or 'trial', for scrape number `m`.
 *
 * @param {?LedgerEntry} entry
 * @param {int} m
 * @returns {string}
 */
export function phase(entry, m) {
	if (entry?.q == null)
		return 'closed';

	return (m <= entry.q) ? 'open' : 'trial';
};

/**
 * The scrapes left before the trial, seen from scrape `m`; null for a closed breaker.
 *
 * @param {?LedgerEntry} entry
 * @param {int} m
 * @returns {?int}
 */
export function left(entry, m) {
	return (entry?.q == null) ? null : max(entry.q - m + 1, 0);
};

/**
 * The cool-down after one of `cd` scrapes: twice it, up to COOLDOWN_MAX.
 *
 * @param {?int} cd
 * @returns {int}
 */
export function next_cooldown(cd) {
	return (cd == null) ? 1 : min(cd * 2, COOLDOWN_MAX);
};

function trip(entry, held, n, why) {
	entry.cd = next_cooldown(held ? entry.cd : null);
	entry.q = n + entry.cd;
	entry.why = why;
	delete entry.f;
	return 'tripped';
}

/**
 * What after() makes of `entry`, made of `entry` itself rather than of a copy.
 *
 * @param {LedgerEntry} entry
 * @param {string} outcome
 * @param {int} n
 * @param {?string} why
 * @returns {?string}
 */
export function apply(entry, outcome, n, why) {
	let held = (entry.q != null);

	switch (outcome) {
	case 'ok':
		delete entry.f;
		if (!held)
			return null;

		delete entry.q;
		delete entry.cd;
		delete entry.why;
		return 'closed';

	case 'trip':
		return trip(entry, held, n, why);

	case 'failed':
		if (held)
			return trip(entry, held, n, why);

		entry.f = (entry.f ?? 0) + 1;
		return (entry.f >= FAILURES) ? trip(entry, held, n, why) : null;
	}

	return null;
};

/**
 * What scrape `n` makes of entry `previous` (left as it is) by an outcome.
 *
 * @param {?LedgerEntry} previous
 * @param {string} outcome
 * @param {int} n
 * @param {?string} why
 * @returns {BreakerChange}
 */
export function after(previous, outcome, n, why) {
	let entry = { ...(previous ?? {}) };
	let change = apply(entry, outcome, n, why);

	return { entry, tripped: change == 'tripped', closed: change == 'closed' };
};
