'use strict';

// The benchmark's budgets: what make bench (and CI) holds the exporter to.
// check(results, absolute) is what is over, as text.
//
// Scaling and memory hold on any machine, as ratios or as a 64-bit ucode's
// memory, which differs little between machines: they are checked
// everywhere. Times depend on the machine: they are checked only with
// `absolute`, in the devenv unconstrained (make bench without BENCH_CPUS).
//
// Each bound leaves room for a slower or busier machine than the one it was
// measured on (a laptop's Ryzen 7840U, where CI's runners are slower), and
// still fails what the bench was written to catch: the earlier exporter
// (2026.09.30-r2) took 9.2 s for 20k conntrack entries, 3.8 s for ethtool
// on 17 ports and 2.2 s for a typical full scrape.

// A case's time per entry may grow this much from the smallest table to the
// largest: linear is 1 (measured 0.95), n log n about 1.4 from 1k to 20k, and
// quadratic 20.
const SCALING = 2.0;

// [ world/case, seconds, what ]
const TIME = [
	// Measured 0.11 s; 2.2 s before.
	[ 'typical/scrape:full', 1.0, 'a typical router\'s full scrape' ],
	// Measured 0.67 s; 12.7 s before.
	[ 'large/scrape:full', 5.0, 'a busy router\'s full scrape' ],
	// Measured 0.41 s; 9.2 s before.
	[ 'large/collector:nat_traffic@20000', 3.0, 'nat_traffic on 20k entries' ],
	// Measured 0.07 s; 3.8 s before.
	[ 'large/collector:ethtool', 1.0, 'ethtool on 17 ports' ],
	// Measured 0.035 s; 0.32 s before.
	[ 'large/collector:snmp6', 0.3, 'snmp6 on 50 devices' ],
	// Measured 0.083 s; 0.48 s before.
	[ 'large/collector:dhcp_leases', 0.5, 'dhcp_leases on 1200 leases' ],
	// Measured 7.8 ms (2000 rounds); 75 ms for 20000 rounds, which nothing refused before.
	[ 'typical/auth:sha512@2000', 0.03, 'basic auth\'s check of a SHA-512-crypt hash of the most rounds it takes' ],
	// Measured 1.0 ms, for 35 collectors.
	[ 'typical/ledger:full', 0.01, 'what the ledger adds to a full scrape' ],
];

// How much of the full check of hash_password's hash (SHA-512-crypt of 1000
// rounds) a request the cache lets in may take: measured about 2% (0.09 ms of
// 4.1 ms in the devenv, 0.5 ms of 19 ms on the R3S, 2.4 ms of 135 ms on a MIPS
// 24Kc); without the cache it is all of it.
const AUTH_CACHED_SHARE = 0.1;

// How much of a typical full scrape the ledger may add: reading it, ordering
// the collectors and recording the scrape under the state's lock. Measured
// under 1% (1.0 ms of 130 ms in the devenv); a scrape that read or wrote it
// per collector, or a ledger that grew with the scrapes, would pass it.
const LEDGER_SHARE = 0.05;

// [ world/case, kB, what ]: how far a run's peak memory may rise, about three
// times what was measured on x86_64 (a 32-bit router's is less), which a
// return of per-sample objects (67 MB for the large full scrape before) or of
// reading the conntrack table whole would pass.
const MEMORY = [
	// Measured 3.8 MB; 10.4 MB before.
	[ 'typical/scrape:full', 12 * 1024, 'a typical router\'s full scrape' ],
	// Measured 16-19 MB; 67 MB before.
	[ 'large/scrape:full', 48 * 1024, 'a busy router\'s full scrape' ],
	// Measured 5.2 MB; 26 MB before.
	[ 'large/collector:nat_traffic@20000', 16 * 1024, 'nat_traffic on 20k entries' ],
];

function by_case(results) {
	let out = {};

	for (let r in results)
		out[`${r.world}/${r.case}`] = r;

	return out;
}

export function check(results, absolute) {
	let r = by_case(results);
	let over = [];

	for (let x in results)
		if (x.ok === false)
			push(over, `${x.world}/${x.case} failed: ${x.error}`);

	// nat_traffic's time per entry, from each table to the largest.
	let tables = sort(map(filter(results, (x) => match(x.case, /^collector:nat_traffic@[0-9]+$/)),
		(x) => [ +split(x.case, '@')[1], x ]), (a, b) => a[0] - b[0]);

	if (length(tables) >= 2) {
		let small = tables[0], big = tables[-1];
		let ratio = (big[1].time.median / big[0]) / (small[1].time.median / small[0]);

		if (ratio > SCALING)
			push(over, sprintf('nat_traffic: %.2f times the time per entry at %d entries as at %d, over %.1f',
				ratio, big[0], small[0], SCALING));
	}

	let full = r['typical/auth:sha512@1000'], cached = r['typical/auth:cached'];

	if (full?.time && cached?.time && cached.time.median > full.time.median * AUTH_CACHED_SHARE)
		push(over, sprintf('auth:cached: %.2f ms, over %d%% of the full check\'s %.2f ms', cached.time.median * 1000,
			AUTH_CACHED_SHARE * 100, full.time.median * 1000));

	let scrape = r['typical/scrape:full'], kept = r['typical/ledger:full'];

	if (scrape?.time && kept?.time && kept.time.median > scrape.time.median * LEDGER_SHARE)
		push(over, sprintf('ledger:full: %.2f ms, over %d%% of a typical full scrape\'s %.1f ms', kept.time.median * 1000,
			LEDGER_SHARE * 100, scrape.time.median * 1000));

	for (let b in MEMORY)
		if (r[b[0]]?.growth_kb > b[1])
			push(over, sprintf('%s (%s): grows %d kB, over %d kB', b[0], b[2], r[b[0]].growth_kb, b[1]));

	if (absolute)
		for (let b in TIME)
			if (r[b[0]]?.time?.median > b[1])
				push(over, sprintf('%s (%s): %.3f s, over %.1f s', b[0], b[2], r[b[0]].time.median, b[1]));

	return over;
};
