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

import { MEMORY_LIMIT_MIN } from 'prometheus.exporter.config';

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
	// Measured 0.18 s on a router's 63 routes, 0.38 s checking each address against each
	// route; 0.21 s before it read the routes, 0.25 s with a call to check each sample's labels, 9.2 s before.
	[ 'large/collector:nat_traffic@20000', 0.6, 'nat_traffic on 20k entries' ],
	// Measured 1.3 ms; 2.4 ms checking each of 400 fields against the
	// default, 6.8 ms matching each against the pattern.
	[ 'large/collector:netstat', 0.004, 'netstat on the kernel\'s 400 fields' ],
	// Measured 10 ms; 12 ms reading 14 sysfs files a link.
	[ 'large/collector:netclass', 0.025, 'netclass on 50 links' ],
	// Measured 3.2 ms; 3.9 ms with a call for each statistic of a link.
	[ 'large/collector:netdev', 0.008, 'netdev on 50 links' ],
	// Measured 9.4 ms; 10.2 ms before.
	[ 'large/collector:wifi', 0.025, 'wifi on 3 radios of 3 networks and 200 stations' ],
	// Measured 0.8 ms; 1.05 ms reading the auxiliary vector's words a
	// byte at a time and /proc/stat with a regex.
	[ 'large/collector:exporter', 0.002, 'the exporter collector' ],
	// Measured 0.8 ms; 1.0 ms with a writer made for each family.
	[ 'large/collector:meminfo', 0.002, 'meminfo\'s 37 families' ],
	// Measured 0.6 ms; 0.9 ms matching each of 170 fields and values.
	[ 'large/collector:vmstat', 0.0015, 'vmstat on the kernel\'s 170 fields' ],
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

// [ world/case, turns, what ]: a case's time in turns of an empty loop of
// the VM (calibrate:vm), which holds on any machine.
const TURNS = [
	// Measured 44,000 turns (10.6 ms); 133,000 checking each address against
	// each route, a function call each.
	[ 'large/collector:nat_traffic@1000', 80000, 'nat_traffic on 1,000 entries and a router\'s 63 routes' ],
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

// How much running each collector in a child process may add to a typical
// full scrape, over running them all in the scrape's own (inline:): a fork,
// a round trip per collector, the runs' file. Measured 10% in the devenv
// (175 ms against 158); a scrape that forked per collector, or copied each
// run's samples more than once, would pass it.
const CONTAINMENT_SHARE = 0.25;

// How much of a typical full scrape its progress file may take: a line
// appended before each collector, the file removed. Measured 0.3 ms of
// 175 ms in the devenv, a fifth of a percent.
const PROGRESS_SHARE = 0.02;

// How much loading every collector first in a child process (probe:) may
// take of loading them alone (load:): it compiles each module, and all it
// imports, alone in the child, and then all of them once, as one program.
// Measured 3.6 times in the devenv (45 ms against 12.5 ms), and 2.2 times
// when the load compiled each alone too.
const PROBE_FACTOR = 5.0;

// The descriptors loading may leave open, per collector (load:full):
// ucode keeps the source of each module it compiled open while the module
// lives, so one per collector and one per module they share, compiled once
// (36 collectors, 41 descriptors). Compiled a program a collector, each
// kept its own copy of the collector API and the four modules behind it:
// 216, which would reach the 1024 a process may open at some 160
// collectors.
const LOAD_FDS_PER_COLLECTOR = 2;

// How much of what its collectors take a typical scrape may add, as
// Prometheus waits for it through uhttpd (handler:): forking the request's
// process and the collectors', reading the config and the ledger, handing
// each run back, rendering and owning every family. By the base
// collectors, light ones, it is mostly what is done once a scrape and once
// a collector: measured 0.8 to 1.05 in the devenv (some 10 ms besides
// 10 ms), where 0.2.0, which read the main section for each collector,
// took 1.6. By every collector it is mostly rendering: measured 0.41 to
// 0.48 in the devenv, 0.33 on QEMU's 24Kc, and 0.53 and 0.48 with 0.2.0,
// whose scrapes on the R3S took 0.35 s besides 0.47 s of collectors.
const HANDLER_SHARE = { 'typical/handler:base': 1.3, 'typical/handler:full': 0.6 };

// How much a sample of each shape may cost the recorder (record:), as a
// multiple of a sample of a labels() set (record:made), which is a lookup
// and a line: a ratio of the VM's own work, which holds on any machine.
// Two labels of an object each, checked and written a lookup and a
// concatenation a label, an int value: measured 2.4 (5.2 us against 2.2 in
// the devenv). The same with a double, written as ucode's 14 digits when
// they read back as it: 3.3. With a call of label_text() and a split of its
// text for each sample, and a double checked for NaN and the infinities
// first, they were 3.6 and 4.5 in the devenv, 3.4 and 4.3 on QEMU's 24Kc.
// With each value and name checked for a NUL byte and a reserved name too,
// eight runs in the devenv gave 2.64 to 2.99 and 3.32 to 3.78: a tenth over
// the most, and still under what label_text() for each sample costs.
const RECORD_FACTOR = { 'typical/record:labels': 3.3, 'typical/record:double': 4.2 };

// What a scrape may cost for each collector besides it (noop:), in seconds:
// its settings, its start and its run in the file the child process writes
// and this one reads, and its four samples of the scrape's own. Measured
// 0.077 ms in the devenv, 0.13 ms in 0.2.1; a scrape that forked a process
// for each collector would pass it.
const PER_COLLECTOR = 0.0005;

// The same, in turns of an empty loop of the VM (calibrate:vm), which holds
// on any machine: measured 330 in the devenv (0.077 ms of 0.234 us) and 310
// on a Cortex-A53, where 0.2.1 took 570 and 510.
const PER_COLLECTOR_TURNS = 450;

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

// [ world/case, kB, what ]: how much the handler's process may hold once it
// loaded a set (rest:), which uhttpd holds for as long as it runs, and every
// scrape's processes start from. Measured 1.44 MB for the base collectors and
// 2.04 MB for every one on x86_64 (a 32-bit router's is less), with the
// native modules the enabled collectors need and zlib loaded when it starts,
// which scrapes then load no more: 1.36 and 1.99 before it loaded them. 0.2.1
// took 2.06 and 2.62, and main of 2026-10-09 1.58 and 2.23 (with basic auth,
// the parser and the grants held besides): any of those held again, a regex
// of a count, or the loader kept, would pass it.
const REST = [
	[ 'typical/rest:base', 1700, 'the handler with the base collectors, at rest' ],
	[ 'typical/rest:full', 2350, 'the handler with every collector, at rest' ],
];

// The most the floor: cases may find, in MB: memory_limit's least
// (prometheus.exporter.config's MEMORY_LIMIT_MIN), which the config takes
// as enough for the handler to load every collector and serve a typical
// scrape of them. Measured 4 MB for the base collectors and 7 for every one
// on x86_64, and less on a 32-bit router.
export const FLOOR_MB = MEMORY_LIMIT_MIN;

// The noop: cases, scrapes of that many collectors that write nothing: the
// difference is what a scrape costs per collector besides it.
export const NOOP = [ 1, 41 ];

// What a scrape costs per collector besides the collector, from the noop:
// cases' results `one` and `many`; null without both.
export function per_collector(one, many) {
	if (!one?.time || !many?.time || many.collectors <= one.collectors)
		return null;

	return (many.time.median - one.time.median) / (many.collectors - one.collectors);
};

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

	let inline = r['typical/inline:full'];

	if (scrape?.time && inline?.time && scrape.time.median > inline.time.median * (1 + CONTAINMENT_SHARE))
		push(over, sprintf('scrape:full: %.1f ms, over %d%% more than inline:full\'s %.1f ms', scrape.time.median * 1000,
			CONTAINMENT_SHARE * 100, inline.time.median * 1000));

	let progress = r['typical/progress:full'];

	if (scrape?.time && progress?.time && progress.time.median > scrape.time.median * PROGRESS_SHARE)
		push(over, sprintf('progress:full: %.2f ms, over %d%% of a typical full scrape\'s %.1f ms', progress.time.median * 1000,
			PROGRESS_SHARE * 100, scrape.time.median * 1000));

	let load = r['large/load:full'], probe = r['large/probe:full'];

	if (load?.time && probe?.time && probe.time.median > load.time.median * PROBE_FACTOR)
		push(over, sprintf('probe:full: %.1f ms, over %.1f times load:full\'s %.1f ms', probe.time.median * 1000,
			PROBE_FACTOR, load.time.median * 1000));

	let loaded = r['large/load:full'];

	if (loaded?.fds != null && loaded.fds > LOAD_FDS_PER_COLLECTOR * loaded.collectors)
		push(over, sprintf('load:full: %d descriptors left open for %d collectors, over %d each', loaded.fds,
			loaded.collectors, LOAD_FDS_PER_COLLECTOR));

	for (let name, share in HANDLER_SHARE) {
		let served = r[name];

		if (served?.time && served.collecting > 0 && served.outside > served.collecting * share)
			push(over, sprintf('%s: %.1f ms besides its collectors\' %.1f ms, over %d%% of them', name, served.outside * 1000,
				served.collecting * 1000, share * 100));
	}

	let made = r['typical/record:made'];

	for (let name, factor in RECORD_FACTOR) {
		let rec = r[name];

		if (rec?.time && made?.time && rec.time.median > made.time.median * factor)
			push(over, sprintf('%s: %.2f us a sample, over %.1f times record:made\'s %.2f us', name,
				rec.time.median / rec.samples * 1000000, factor, made.time.median / made.samples * 1000000));
	}

	let each = per_collector(r[`typical/noop:${NOOP[0]}`], r[`typical/noop:${NOOP[1]}`]);

	if (absolute && each != null && each > PER_COLLECTOR)
		push(over, sprintf('noop: %.3f ms a collector besides it, over %.3f ms', each * 1000, PER_COLLECTOR * 1000));

	let vm = r['large/calibrate:vm'];

	if (each != null && vm?.loop_us > 0 && each * 1000000 / vm.loop_us > PER_COLLECTOR_TURNS)
		push(over, sprintf('noop: %.0f loop turns a collector besides it, over %d', each * 1000000 / vm.loop_us, PER_COLLECTOR_TURNS));

	for (let b in TURNS)
		if (vm?.loop_us > 0 && r[b[0]]?.time && r[b[0]].time.median * 1000000 / vm.loop_us > b[1])
			push(over, sprintf('%s (%s): %.0f loop turns, over %d', b[0], b[2], r[b[0]].time.median * 1000000 / vm.loop_us, b[1]));

	for (let b in MEMORY)
		if (r[b[0]]?.growth_kb > b[1])
			push(over, sprintf('%s (%s): grows %d kB, over %d kB', b[0], b[2], r[b[0]].growth_kb, b[1]));

	for (let b in REST)
		if (r[b[0]]?.held_kb > b[1])
			push(over, sprintf('%s (%s): holds %d kB, over %d kB', b[0], b[2], r[b[0]].held_kb, b[1]));

	for (let x in results)
		if (x.kind == 'floor' && x.floor_mb > FLOOR_MB)
			push(over, sprintf('%s/%s: a scrape needs a memory_limit of %d MB, over memory_limit\'s least, %d MB',
				x.world, x.case, x.floor_mb, FLOOR_MB));

	if (absolute)
		for (let b in TIME)
			if (r[b[0]]?.time?.median > b[1])
				push(over, sprintf('%s (%s): %.3f s, over %.1f s', b[0], b[2], r[b[0]].time.median, b[1]));

	return over;
};
