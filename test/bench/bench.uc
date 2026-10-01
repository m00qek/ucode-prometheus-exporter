'use strict';

// The benchmark: runs each case of run.uc in a process of its own, prints a
// table and writes the results as JSON; with -c, checks them against the
// scaling budgets (budgets.uc), with -a the time budgets of the devenv too,
// and exits 1 when one is over.
//
//   ucode -L src -L test test/bench/bench.uc -w WORLDS -o OUT.json [-l LABEL] [-f REGEX]
//         [-t MIN_SECONDS] [-r MIN_REPS] [-c [-a]]
//
// WORLDS is gen.uc's output directory, with sets.json: the collector sets
// { base: [ names ], full: [ names ] }. The cases:
//
//   load:base, load:full          compiling the collectors, as uhttpd does when it starts
//   collector:<name>              each collector of `full` on the large world
//   collector:nat_traffic@<n>     the n-entry conntrack tables (1k, 10k, 20k)
//   scrape:base, scrape:full      whole scrapes, on the typical and the large world

import * as fs from 'fs';
import * as budgets from 'bench.budgets';

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
let here = fs.dirname(sourcepath());
let src = fs.realpath(`${here}/../../src`), test = fs.realpath(`${here}/..`);

// [ world, case ]
let cases = [ [ 'large', 'load:base' ], [ 'large', 'load:full' ] ];

for (let n in sets.full)
	if (n != 'nat_traffic')
		push(cases, [ 'large', `collector:${n}` ]);
for (let n in json(fs.readfile(`${args.worlds}/large/world.json`)).sizes.conntrack_scaling)
	push(cases, [ 'large', `collector:nat_traffic@${n}` ]);
for (let w in [ 'typical', 'large' ])
	for (let s in [ 'base', 'full' ])
		push(cases, [ w, `scrape:${s}` ]);

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

	return { model, cpu, cpus, kernel: trim(fs.readfile('/proc/sys/kernel/osrelease') ?? '') };
}

function run(world, name) {
	let cmd = sprintf("ucode -L '%s' -L '%s' '%s/run.uc' '%s/%s' '%s' %s %d 2>&1",
		src, test, here, args.worlds, world, name, '' + args.min_seconds, args.min_reps);
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
	if (r.kind == 'scrape')
		note = sprintf('collectors %s ms, outside %s ms, load %s ms %s', ms(r.collecting), ms(r.outside), ms(r.load), note);

	print(sprintf('%-8s %-32s %10s %10s %10s %8s %9s  %s\n', c[0], c[1], ms(r.time?.min), ms(r.time?.median),
		ms(r.render?.min), r.samples ?? '-', r.growth_kb ?? '-', note));
}

let report = { label: args.label, date: time(), host: host(), min_seconds: args.min_seconds, min_reps: args.min_reps, results };
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
