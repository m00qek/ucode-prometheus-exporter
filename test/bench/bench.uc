'use strict';

// The benchmark: runs each case of run.uc, a process for each run (as uhttpd
// forks one per request), at least MIN_REPS times (3) and until MIN_SECONDS
// (1) are spent, at most 10 times; prints a table of the fastest and the
// median run and the largest peak, and writes the results as JSON. With -c it
// checks them against the scaling and memory budgets (budgets.uc), with -a
// the time budgets of the devenv too, and exits 1 when one is over.
//
//   ucode -L src -L test test/bench/bench.uc -w WORLDS -o OUT.json [-l LABEL] [-f REGEX]
//         [-t MIN_SECONDS] [-r MIN_REPS] [-c [-a]]
//
// WORLDS is gen.uc's output directory, with sets.json: the collector sets
// { base: [ names ], full: [ names ], extra: [ names ] }, extra those in no
// group that are benched alone too. The cases:
//
//   load:base, load:full          compiling the collectors
//   probe:full                    the same, each loaded in a child process first, as uhttpd does when it starts
//   rest:base, rest:full          what the handler's process holds once it loaded the set, as uhttpd
//                                 holds it while it runs (RssAnon)
//   lazy:<what>                   what a scrape's process pays to load what uhttpd no longer holds,
//                                 the first time it needs it: the exposition parser, zlib, and the
//                                 native modules ubus, rtnl and nl80211
//   collector:<name>              each collector of `full` and `extra` on the large world
//   collector:nat_traffic@<n>     the n-entry conntrack tables (1k, 10k, 20k)
//   scrape:base, scrape:full      whole scrapes, on the typical and the large world, as the service
//                                 makes them: each collector in a child process
//   inline:base, inline:full      the same scrapes, every collector in the scrape's own process
//   handler:base, handler:full    the typical world's scrapes as Prometheus gets them: through uhttpd
//                                 and the service's handler, the ledger, the progress file and the
//                                 deadline; where uhttpd and its ucode plugin are, and find this exporter
//   floor:base, floor:full        the least memory_limit under which uhttpd loads the handler with the
//                                 set and the typical world's scrape of it succeeds whole; where uhttpd
//                                 cannot run this exporter, under which scrape:<set>'s process does;
//                                 and the large world's full scrape, a busy router's
//   progress:full                 a scrape's progress file in the state
//   auth:<hash>, auth:cached      basic auth's check of a password, by each hash and by the cache
//   ledger:full                   what the ledger in the state adds to a full scrape
//   deadline:full@<n>             a full scrape for a 10 s timeout, nat_traffic on the n-entry table
//   noop:<n>                      a scrape of n collectors that write nothing: noop:1 and noop:41
//                                 give what a scrape costs for each collector besides it
//   record:<shape>                the recorder's cost per sample, for each shape of sample

import * as fs from 'fs';
import * as budgets from 'bench.budgets';
import * as auth from 'prometheus_exporter.auth';
import * as uhttpd from 'bench.server';

function usage() {
	warn('usage: bench.uc -w WORLDS -o OUT.json [-l LABEL] [-f REGEX] [-t MIN_SECONDS] [-r MIN_REPS] [-c [-a]]\n');
	exit(2);
}

let args = { worlds: null, out: null, label: 'bench', filter: null, min_seconds: 1, min_reps: 3, check: false, absolute: false };

for (let i = 0; i < length(ARGV); i++) {
	let a = ARGV[i];

	switch (a) {
	case '-w': args.worlds = ARGV[++i]; break;
	case '-o': args.out = ARGV[++i]; break;
	case '-l': args.label = ARGV[++i]; break;
	case '-f': args.filter = regexp(ARGV[++i]); break;
	case '-t': args.min_seconds = +ARGV[++i]; break;
	case '-r': args.min_reps = +ARGV[++i]; break;
	case '-c': args.check = true; break;
	case '-a': args.absolute = true; break;
	default: usage();
	}
}

if (!args.worlds || !args.out)
	usage();

let sets = json(fs.readfile(`${args.worlds}/sets.json`) ?? die(`no ${args.worlds}/sets.json`));
// The exporter is the source tree's beside the bench, or else the installed
// one (/usr/share/ucode), as in QEMU, where the packages are installed.
let here = fs.dirname(sourcepath());
let src = fs.realpath(`${here}/../../src`), test = fs.realpath(`${here}/..`);
let search = (src ? `-L '${src}' ` : '') + `-L '${test}'`;

// [ world, case ]
let cases = [ [ 'large', 'calibrate:vm' ], [ 'large', 'load:base' ], [ 'large', 'load:full' ], [ 'large', 'probe:full' ] ];

// An extra collector is benched where it is there: the installed exporter
// (QEMU's) has the -full group's alone.
let extra = filter(sets.extra ?? [], (n) => src || fs.stat(`/usr/share/ucode/prometheus_exporter/collectors/${replace(n, '-', '_')}.uc`));

for (let n in [ ...sets.full, ...extra ])
	if (n != 'nat_traffic')
		push(cases, [ 'large', `collector:${n}` ]);
for (let n in json(fs.readfile(`${args.worlds}/large/world.json`)).sizes.conntrack_scaling)
	push(cases, [ 'large', `collector:nat_traffic@${n}` ]);
for (let w in [ 'typical', 'large' ])
	for (let s in [ 'base', 'full' ])
		push(cases, [ w, `scrape:${s}` ], [ w, `inline:${s}` ]);

// Through uhttpd, where the exporter it would load is this one.
let no_handler = uhttpd.missing(src);

if (no_handler)
	warn(`no handler: cases: ${no_handler}\n`);
else
	for (let s in [ 'base', 'full' ])
		push(cases, [ 'typical', `handler:${s}` ]);
for (let s in [ 'base', 'full' ])
	push(cases, [ 'typical', `floor:${s}` ]);
push(cases, [ 'large', 'floor:full' ]);
push(cases, [ 'typical', 'rest:base' ], [ 'typical', 'rest:full' ]);
for (let l in [ 'parse', 'zlib', 'ubus', 'rtnl', 'nl80211' ])
	push(cases, [ 'typical', `lazy:${l}` ]);
push(cases, [ 'typical', 'progress:full' ]);
// Basic auth's check of a password: MD5-crypt, SHA-512-crypt at the rounds
// hash_password makes, SHA-crypt at the most auth_password takes, and a
// request let in by the cache.
for (let c in [ 'md5', `sha512@${auth.HASH_ROUNDS}`, `sha256@${auth.ROUNDS_MAX}`, `sha512@${auth.ROUNDS_MAX}`, 'cached' ])
	push(cases, [ 'typical', `auth:${c}` ]);
push(cases, [ 'typical', 'ledger:full' ]);
for (let n in budgets.NOOP)
	push(cases, [ 'typical', `noop:${n}` ]);
for (let shape in [ 'labels', 'double', 'family', 'made' ])
	push(cases, [ 'typical', `record:${shape}` ]);
push(cases, [ 'large', `deadline:full@${max(...json(fs.readfile(`${args.worlds}/large/world.json`)).sizes.conntrack_scaling)}` ]);

if (args.filter)
	cases = filter(cases, (c) => match(`${c[0]}/${c[1]}`, args.filter));

function host() {
	let cpu = null;

	for (let line in split(fs.readfile('/proc/cpuinfo') ?? '', '\n')) {
		let m = match(line, /^(model name|cpu model|Hardware|CPU part)\s*:\s*(.*)$/);
		if (m) {
			cpu = m[2];
			break;
		}
	}

	let cpus = length(filter(split(fs.readfile('/proc/cpuinfo') ?? '', '\n'), (l) => match(l, /^processor\s*:/)));
	let model = trim(fs.readfile('/tmp/sysinfo/model') ?? '') || null;

	let bogomips = match(fs.readfile('/proc/cpuinfo') ?? '', /BogoMIPS\s*:\s*([0-9.]+)/i);

	return { model, cpu, cpus, bogomips: bogomips ? +bogomips[1] : null, kernel: trim(fs.readfile('/proc/sys/kernel/osrelease') ?? '') };
}

function run_once(world, name) {
	let cmd = sprintf("ucode %s '%s/run.uc' '%s/%s' '%s' 2>&1", search, here, args.worlds, world, name);
	let p = fs.popen(cmd, 'r');
	let out = p.read('all');
	let status = p.close();
	let lines = filter(split(out, '\n'), length);
	let res = null;

	try {
		res = json(lines[-1]);
	} catch (e) {
		res = null;
	}

	if (status != 0 || type(res) != 'object')
		return { case: name, ok: false, error: `exit ${status}: ${join(' | ', slice(lines, -3))}` };

	return res;
}

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

function median(list) {
	let s = sort([ ...list ], (a, b) => a - b);
	let n = length(s);

	return n % 2 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
}

function stats(list) {
	list = filter(list, (v) => v != null);
	return length(list) ? { min: min(...list), median: median(list) } : null;
}

// A case's runs as one result: the last run's, with the times of all of them,
// and the largest peak. A run that fails ends the case.
function run(world, name) {
	let runs = [];
	let started = now();

	while (length(runs) < args.min_reps || (now() - started < args.min_seconds && length(runs) < 10)) {
		let r = run_once(world, name);

		push(runs, r);
		if (r.ok === false && r.time == null)
			return r;
	}

	return {
		...runs[-1],
		reps: length(runs),
		time: stats(map(runs, (r) => r.time)),
		render: stats(map(runs, (r) => r.render)),
		// A scrape's medians: its collectors' durations, and the rest.
		collecting: stats(map(runs, (r) => r.collecting))?.median,
		outside: stats(map(runs, (r) => r.outside))?.median,
		hwm_kb: max(...map(runs, (r) => r.hwm_kb ?? 0)),
		growth_kb: max(...map(runs, (r) => r.growth_kb ?? 0)),
	};
}

function ms(s) {
	return s == null ? '-' : sprintf('%.1f', s * 1000);
}

let results = [];

print(sprintf('%-8s %-32s %10s %10s %10s %8s %9s  %s\n', 'world', 'case', 'min ms', 'median ms', 'render ms', 'samples', 'grows kB', 'note'));
for (let c in cases) {
	let r = run(c[0], c[1]);

	r.world = c[0];
	push(results, r);

	let note = r.ok === false ? (r.error ?? 'failed') : '';
	if (r.kind == 'calibrate')
		note = sprintf('%.3f us a loop turn, %.3f us a builtin call, %.1f ms a program run', r.loop_us, r.call_us, r.exec_ms);
	if (r.kind == 'deadline')
		note = sprintf('%s; left out: %s', (r.first != null) ? sprintf('first %.1f ms', r.first * 1000) : 'ledger kept', join(' ', r.left_out ?? []) || 'none') +
			(r.ok === false ? ` ${r.error}` : '');
	if (r.kind == 'progress' && r.ok !== false)
		note = sprintf('%d collectors', r.collectors);
	if (r.kind == 'ledger' && r.ok !== false)
		note = sprintf('%d collectors, %d bytes', r.collectors, r.bytes);
	if (r.kind == 'auth' && r.ok !== false)
		note = r.cached ? 'by the cache' : sprintf('%d rounds', r.rounds);
	if (r.kind == 'noop' && r.ok !== false) {
		let one = filter(results, (x) => x.case == `noop:${budgets.NOOP[0]}`)[0];

		r.per_collector = budgets.per_collector(one, r);
		note = sprintf('%d collectors%s', r.collectors, (r.per_collector != null) ? sprintf(', %.3f ms each', r.per_collector * 1000) : '');
	}
	if (r.kind == 'record' && r.ok !== false)
		note = sprintf('%.3f us a sample', r.time.median / r.samples * 1000000);
	if (r.kind == 'floor' && r.floor_mb != null)
		note = sprintf('%d collectors, memory_limit %d MB, by %s (tried %s)', r.collectors, r.floor_mb, r.via, join(' ', r.tried));
	if (r.kind == 'lazy' && r.ok !== false)
		note = r.loaded ? '' : 'not installed';
	if (r.kind == 'rest' && r.held_kb != null)
		note = sprintf('%d collectors, holds %d kB, RssAnon %d kB', r.collectors, r.held_kb, r.anon_kb);
	if (r.kind == 'load' || r.kind == 'probe')
		note = sprintf('%d collectors, %d fds, RSS %d kB', r.collectors, r.fds, r.rss_kb);
	if (r.kind == 'handler' && r.time)
		note = sprintf('collectors %s ms, outside %s ms, uhttpd %d fds, RSS %d kB %s', ms(r.collecting), ms(r.outside),
			r.server_fds, r.server_rss_kb, note);
	if (r.kind == 'scrape' || r.kind == 'inline') {
		let top = slice(sort(keys(r.durations ?? {}), (a, b) => r.durations[b] - r.durations[a]), 0, 4);
		note = sprintf('collectors %s ms (%s), outside %s ms, load %s ms%s %s', ms(r.collecting),
			join(' ', map(top, (n) => `${n} ${ms(r.durations[n])}`)), ms(r.outside), ms(r.load),
			(r.child_hwm_kb != null) ? sprintf(', data %d kB, child peak %d kB data %d kB', r.data_kb, r.child_hwm_kb, r.child_data_kb) : '', note);
	}

	print(sprintf('%-8s %-32s %10s %10s %10s %8s %9s  %s\n', c[0], c[1], ms(r.time?.min), ms(r.time?.median),
		ms(r.render?.min), r.samples ?? '-', r.growth_kb ?? '-', note));
}

let report = { label: args.label, date: time(), host: host(), exporter: src ?? 'installed', min_seconds: args.min_seconds, min_reps: args.min_reps, results };
let status = 0;

if (args.check) {
	let over = budgets.check(results, args.absolute);

	report.budgets = over;
	for (let o in over)
		print(`over budget: ${o}\n`);
	if (length(over))
		status = 1;
	else
		print('every budget holds\n');
}

fs.writefile(args.out, sprintf('%.J\n', report));
print(`results: ${args.out}\n`);
exit(status);
