'use strict';

// A collector's circuit breaker, counted in scrapes of the instance: what the
// ledger (prometheus_exporter.ledger) keeps of it, and how a scrape's outcome
// changes it. Pure: no time, no files.
//
// A breaker is closed while the collector does its job. It trips (opens) when
// the collector
// - had a program killed at its own timeout (COMMAND_TIMEOUT),
// - took longer than its budget (OVERRUN), or
// - failed FAILURES scrapes in a row (nothing to observe is a success).
// The collector is then quarantined: not run for a cool-down of 1 scrape the
// first time, then 2, 4, and so on, at most COOLDOWN_MAX. The scrape after
// the cool-down is its trial: success closes the breaker, any failure trips
// it again for twice the cool-down. A collector the deadline left out has
// neither succeeded nor failed: its breaker is as it was.
//
// An entry's fields (absent: the default):
//   f   failures in a row while closed (0)
//   q   the last scrape number of the quarantine (none: closed)
//   cd  the cool-down that quarantine was for, in scrapes
//   why what tripped it: an error code and its detail

// Failures in a row that trip a breaker. One failure is often a passing one:
// a service restarting, a reload, a ubus call while netifd is busy. Three in a
// row, 45 seconds of them at a 15-second interval or 3 minutes at a minute's,
// is a collector that fails, which then stops logging a line every scrape.
export const FAILURES = 3;

// The most scrapes a quarantine lasts: 1, 2, 4, 8, 16, 32. A collector that
// is fixed is served again within 32 scrapes, 8 minutes at Prometheus's
// interval of 15 seconds, 32 at vmagent's minute; a broken one costs a scrape
// at most one trial in 32, and a trial is bounded by the collector's budget
// and the scrape's deadline.
export const COOLDOWN_MAX = 32;

// 'closed', 'open' (quarantined) or 'trial', for scrape number `m`.
export function phase(e, m) {
	if (e?.q == null)
		return 'closed';

	return (m <= e.q) ? 'open' : 'trial';
};

// The scrapes left before the trial, seen from scrape number `m`: 0 when `m`
// is the trial; null for a closed breaker.
export function left(e, m) {
	return (e?.q == null) ? null : max(e.q - m + 1, 0);
};

// The cool-down after one of `cd` scrapes: twice it, up to COOLDOWN_MAX.
export function next_cooldown(cd) {
	return (cd == null) ? 1 : min(cd * 2, COOLDOWN_MAX);
};

// What scrape `n` makes of entry `e` (left as it is) by an outcome:
//   'ok'      the collector succeeded, within its budget
//   'failed'  it failed
//   'trip'    a program was killed at its timeout, or it overran its budget
//   'neutral' it did not run, or the deadline cut it short
// { entry, tripped, closed }: the new entry, and whether the breaker tripped
// or closed. `why` says what tripped it.
export function after(e, outcome, n, why) {
	let entry = { ...(e ?? {}) };
	let held = (entry.q != null);

	function trip() {
		entry.cd = next_cooldown(held ? entry.cd : null);
		entry.q = n + entry.cd;
		entry.why = why;
		delete entry.f;
		return { entry, tripped: true, closed: false };
	}

	switch (outcome) {
	case 'ok':
		delete entry.f;
		if (held) {
			delete entry.q;
			delete entry.cd;
			delete entry.why;
		}
		return { entry, tripped: false, closed: held };

	case 'trip':
		return trip();

	case 'failed':
		// A trial that fails trips again; a closed breaker after FAILURES.
		if (held)
			return trip();

		entry.f = (entry.f ?? 0) + 1;
		return (entry.f >= FAILURES) ? trip() : { entry, tripped: false, closed: false };
	}

	return { entry, tripped: false, closed: false };
};
