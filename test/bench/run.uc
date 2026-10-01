'use strict';

// One run of a benchmark case, in a process of its own, as uhttpd answers
// each request in a process of its own, forked from the one that loaded the
// exporter: nothing a run leaves (memos, garbage) is there for the next, and
// the peak memory is this run's. Prints one JSON object; bench.uc runs it as
// many times as it times a case.
//
//   ucode -L src -L test test/bench/run.uc WORLD CASE
//
// CASE is
//   calibrate:vm              the VM's own speed: an empty loop's turn and a builtin's call
//   load:<set>                compile and validate the set's collectors, as uhttpd does when it starts
//   collector:<name>[@<n>]    one collector's run and its rendering; @n reads the n-entry conntrack table
//   scrape:<set>              a whole scrape of the set, as uhttpd answers /metrics
//
// A set is one named in WORLD/../sets.json: base, full (base and the -full group).

import * as fs from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as scrape from 'prometheus_exporter.scrape';
import * as exposition from 'prometheus_exporter.exposition';
import * as Result from 'prometheus_exporter.result';
import * as bench_world from 'bench.world';

const STATUS = /^(VmHWM|VmRSS):\s+([0-9]+) kB/;
const DURATION = /^node_scrape_collector_duration_seconds\{collector="([^"]+)"\} (.*)$/;
const FAILED = /^node_scrape_collector_success\{collector="([^"]+)"\} 0$/;

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

// { VmHWM, VmRSS } in kB.
function memory() {
	let m = {};

	for (let line in split(fs.readfile('/proc/self/status') ?? '', '\n')) {
		let f = match(line, STATUS);
		if (f)
			m[f[1]] = +f[2];
	}

	return m;
}

// Frees what loading left and, where the kernel lets a process (Linux 4.0's
// clear_refs, which OpenWrt's kernels leave out), starts VmHWM again from the
// current RSS: the peak is then the run's own.
function reset_peak() {
	gc();
	fs.writefile('/proc/self/clear_refs', '5');
	return memory();
}

function samples(text) {
	let n = 0;

	for (let line in split(text, '\n'))
		if (line != '' && substr(line, 0, 1) != '#')
			n++;

	return n;
}

let world_dir = ARGV[0], name = ARGV[1];
let world = bench_world.load(world_dir);
let sets = json(fs.readfile(`${world_dir}/../sets.json`) ?? die('no sets.json beside the world'));
let logs = [];
let log = (level, msg) => push(logs, `${level}: ${msg}`);
let kind = split(name, ':')[0], arg = split(name, ':')[1];

// The collectors of a set, loaded as the exporter loads them.
function load_set(set) {
	let names = sets[set] ?? die(`no set ${set}`);
	let out = [];

	for (let n in names) {
		let id = loader.id_of(n);
		let res = loader.validate(id, loader.import_module(id));

		if (!res.ok)
			die(Result.describe(res));
		push(out, res.data);
	}

	return out;
}

let result = { case: name, kind };
let mem_before;

if (kind == 'calibrate') {
	// The VM's speed, which every case is a multiple of: µs per turn of an
	// empty loop and per call of a builtin, to compare machines by.
	mem_before = memory();

	let n = 200000, t = now();
	for (let i = 0; i < n; i++)
		;
	result.loop_us = (now() - t) * 1000000 / n;

	t = now();
	for (let i = 0; i < n; i++)
		length('abc');
	result.call_us = (now() - t) * 1000000 / n - result.loop_us;

	// A program run as a collector's are, under deps' watchdog: a shell, its
	// two subshells and the program (false, which the world has no output for).
	let exec = deps.exec_channel(bench_world.modules(world, []).fs.popen, [ 'probe' ], 30);
	n = 10;
	t = now();
	for (let i = 0; i < n; i++)
		exec.run([ 'probe' ]);
	result.exec_ms = (now() - t) * 1000 / n;
	result.time = result.loop_us / 1000000;
} else if (kind == 'load') {
	mem_before = reset_peak();

	let t = now();
	result.collectors = length(load_set(arg));
	result.time = now() - t;
} else if (kind == 'collector') {
	let parts = split(arg, '@');
	let entries = parts[1] != null ? +parts[1] : null;
	let id = loader.id_of(parts[0]);
	let c = loader.validate(id, loader.import_module(id));

	if (!c.ok)
		die(Result.describe(c));
	c = c.data;

	let redirect = entries != null ? { '/proc/net/nf_conntrack': `${world_dir}/conntrack/${entries}` } : {};
	let mods = bench_world.modules(world, c.meta.needs, { redirect });
	let env = { clock: () => clock(true), log };

	mem_before = reset_peak();

	let t = now();
	let session = deps.session({ ...mods, log });
	let run = scrape.run_one(env, session, c);
	session.close();
	result.time = now() - t;

	t = now();
	let text = exposition.render(run.families);
	result.render = now() - t;

	result.collector = parts[0];
	result.entries = entries;
	result.ok = run.result.ok;
	result.error = run.result.ok ? null : Result.describe(run.result);
	result.samples = samples(text);
	result.bytes = length(text);
} else if (kind == 'scrape') {
	let t = now();
	let collectors = load_set(arg);
	let needs = [];

	result.load = now() - t;
	for (let c in collectors)
		push(needs, ...c.meta.needs);

	let mods = bench_world.modules(world, uniq(needs));
	let env = { session: () => deps.session({ ...mods, log }), clock: () => clock(true), log, version: 'bench' };

	mem_before = reset_peak();

	t = now();
	let res = scrape.scrape(env, collectors, '');
	result.time = now() - t;

	let collecting = 0, failed = [];

	result.durations = {};
	for (let line in split(res.body, '\n')) {
		let m = match(line, DURATION);
		if (m) {
			collecting += +m[2];
			result.durations[m[1]] = +m[2];
		}
		m = match(line, FAILED);
		if (m)
			push(failed, m[1]);
	}

	result.set = arg;
	result.collectors = length(collectors);
	result.ok = res.status == '200 OK' && !length(failed);
	result.error = length(failed) ? `failed: ${join(' ', failed)}` : null;
	// The collectors' own durations, and the rest (config, selection, merging,
	// rendering).
	result.collecting = collecting;
	result.outside = result.time - collecting;
	result.samples = samples(res.body);
	result.bytes = length(res.body);
} else {
	die(`unknown case ${name}`);
}

let mem = memory();
// The process's peak, and how far it rose above what the process held
// before the run began (ucode, the modules and the world's data it reads).
result.hwm_kb = mem.VmHWM;
result.rss_before_kb = mem_before.VmRSS;
result.growth_kb = mem.VmHWM - mem_before.VmRSS;
result.logs = slice(uniq(logs), 0, 5);

print(sprintf('%J\n', result));
