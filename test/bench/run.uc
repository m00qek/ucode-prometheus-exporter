'use strict';

// One benchmark case, in a process of its own so its peak memory is its own;
// prints one JSON object. bench.uc runs it for each case.
//
//   ucode -L src -L test test/bench/run.uc WORLD CASE [MIN_SECONDS] [MIN_REPS]
//
// CASE is
//   load:<set>                compile and validate the set's collectors, as uhttpd does when it starts
//   collector:<name>[@<n>]    one collector's run and its rendering; @n reads the n-entry conntrack table
//   scrape:<set>              a whole scrape of the set, as uhttpd answers /metrics
//
// A set is one named in WORLD/../sets.json: base, full (base and the -full group).
// Each is timed over at least MIN_REPS runs (3) and MIN_SECONDS (1) in all,
// after one run that is not counted (none when MIN_REPS is 1); the minimum and
// the median are reported.

import * as fs from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as scrape from 'prometheus_exporter.scrape';
import * as exposition from 'prometheus_exporter.exposition';
import * as Result from 'prometheus_exporter.result';
import * as bench_world from 'bench.world';

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

// { VmHWM, VmRSS } in kB.
function memory() {
	let m = {};

	for (let line in split(fs.readfile('/proc/self/status') ?? '', '\n')) {
		let f = match(line, /^(VmHWM|VmRSS):\s+([0-9]+) kB/);
		if (f)
			m[f[1]] = +f[2];
	}

	return m;
}

// Starts VmHWM again from the current RSS (Linux 4.0's clear_refs), after
// freeing what loading the world left: the peak is then the case's own.
function reset_peak() {
	gc();
	fs.writefile('/proc/self/clear_refs', '5');
	return memory();
}

function median(list) {
	let s = sort([ ...list ], (a, b) => a - b);
	let n = length(s);

	return n % 2 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
}

function stats(list) {
	return { min: length(list) ? min(...list) : null, median: length(list) ? median(list) : null };
}

// fn() timed as the header says; fn returns what to keep of the last run.
// What a run leaves is collected before the next, untimed: the peak memory is
// one run's, not the garbage of many.
function repeat(min_seconds, min_reps, fn, max_reps) {
	let times = [];
	// The run that warms up is skipped when a single run is asked for, as on
	// a slow machine where each takes long.
	let last = min_reps > 1 ? fn() : null;
	let started = now();

	while (length(times) < min_reps || (now() - started < min_seconds && length(times) < (max_reps ?? 50))) {
		last = null;
		gc();

		let t = now();
		last = fn();
		push(times, now() - t);
	}

	return { times, last };
}

function samples(text) {
	let n = 0;

	for (let line in split(text, '\n'))
		if (line != '' && substr(line, 0, 1) != '#')
			n++;

	return n;
}

let world_dir = ARGV[0], name = ARGV[1];
let min_seconds = +(ARGV[2] ?? 1), min_reps = +(ARGV[3] ?? 3);
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

let mem_before = reset_peak();
let result = { case: name, kind };

if (kind == 'load') {
	// At most 5 loads: ucode keeps each compiled module's file open, and a
	// load of `full` opens over a hundred, of the process's 1024.
	let r = repeat(min_seconds, min_reps, () => length(load_set(arg)), 5);

	result.collectors = r.last;
	result.time = stats(r.times);
	result.reps = length(r.times);
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
	let render_times = [];

	mem_before = reset_peak();

	let r = repeat(min_seconds, min_reps, function() {
		let session = deps.session({ ...mods, log });
		let run = scrape.run_one(env, session, c);
		session.close();

		let t = now();
		let text = exposition.render(run.families);
		push(render_times, now() - t);

		return { ok: run.result.ok, error: run.result.ok ? null : Result.describe(run.result), text };
	});

	result.collector = parts[0];
	result.entries = entries;
	result.ok = r.last.ok;
	result.error = r.last.error;
	result.time = stats(r.times);
	result.reps = length(r.times);
	result.render = stats(slice(render_times, length(render_times) - length(r.times)));
	result.samples = samples(r.last.text);
	result.bytes = length(r.last.text);
} else if (kind == 'scrape') {
	let t = now();
	let collectors = load_set(arg);
	let load_time = now() - t;
	let needs = [];
	for (let c in collectors)
		push(needs, ...c.meta.needs);
	let mods = bench_world.modules(world, uniq(needs));
	let env = { session: () => deps.session({ ...mods, log }), clock: () => clock(true), log, version: 'bench' };

	mem_before = reset_peak();

	let r = repeat(min_seconds, min_reps, () => scrape.scrape(env, collectors, ''));
	let body = r.last.body;
	let collecting = 0, failed = [];

	for (let line in split(body, '\n')) {
		let m = match(line, /^node_scrape_collector_duration_seconds\{collector="([^"]+)"\} (.*)$/);
		if (m)
			collecting += +m[2];
		m = match(line, /^node_scrape_collector_success\{collector="([^"]+)"\} 0$/);
		if (m)
			push(failed, m[1]);
	}

	result.set = arg;
	result.collectors = length(collectors);
	result.load = load_time;
	result.ok = r.last.status == '200 OK' && !length(failed);
	result.error = length(failed) ? `failed: ${join(' ', failed)}` : null;
	result.time = stats(r.times);
	result.reps = length(r.times);
	// Of the last scrape: the collectors' own durations, and the rest
	// (config, selection, merging, rendering).
	result.collecting = collecting;
	result.outside = r.times[-1] - collecting;
	result.samples = samples(body);
	result.bytes = length(body);
} else {
	die(`unknown case ${name}`);
}

let mem = memory();
// The process's peak, and how far it rose above what the process held
// before the case began (ucode, the modules and the world's data).
result.hwm_kb = mem.VmHWM;
result.rss_before_kb = mem_before.VmRSS;
result.growth_kb = mem.VmHWM - mem_before.VmRSS;
result.logs = slice(uniq(logs), 0, 5);

print(sprintf('%J\n', result));
