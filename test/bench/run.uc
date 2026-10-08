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
//   load:<set>                compile and validate the set's collectors
//   probe:<set>               the same, each module loaded in a child process first, as uhttpd does
//                             when it starts (prometheus_exporter.probe)
//   handler:<set>             a scrape of the set as Prometheus gets it: uhttpd running the
//                             service's handler (handler.uc, on the world), asked by wget
//   collector:<name>[@<n>]    one collector's run and its rendering; @n reads the n-entry conntrack table
//   scrape:<set>              a whole scrape of the set, as uhttpd answers /metrics: each collector
//                             in a child process (prometheus_exporter.runner's forked)
//   inline:<set>              the same scrape, every collector in the scrape's own process, as
//                             before; scrape less inline is what running them apart costs
//   progress:<set>            a scrape's progress file: a line for each collector of the set,
//                             appended to its file in the state, and the file removed
//   auth:md5                  basic auth's check of a password against a $1$ hash
//   auth:<sha256|sha512>@<n>  the same against a $5$ or $6$ hash of n rounds
//   auth:cached               the same by the cache a check before left (hash_password's hash)
//   deadline:<set>@<n>        a scrape of the set as the handler makes it for Prometheus's
//                             default 10 s timeout, nat_traffic reading the n-entry table:
//                             after a first scrape that leaves the ledger, the time to
//                             answer, which must be within the timeout
//   ledger:<set>              what the ledger adds to a scrape of the set: reading and
//                             parsing it, ordering the collectors, and recording the
//                             scrape under the state's lock, with every collector in it
//
// A set is one named in WORLD/../sets.json: base, full (base and the -full group).

import * as fs from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as scrape from 'prometheus_exporter.scrape';
import * as exposition from 'prometheus_exporter.exposition';
import * as Result from 'prometheus_exporter.result';
import * as auth from 'prometheus_exporter.auth';
import * as crypt from 'prometheus_exporter.crypt';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';
import * as deadline from 'prometheus_exporter.deadline';
import * as runner from 'prometheus_exporter.runner';
import { probe as probe_modules } from 'prometheus_exporter.probe';
import * as bench_world from 'bench.world';
import * as uhttpd from 'bench.server';

const STATUS = /^(VmHWM|VmRSS|VmData):\s+([0-9]+) kB/;
const DURATION = /^node_scrape_collector_duration_seconds\{collector="([^"]+)"\} (.*)$/;
const FAILED = /^node_scrape_collector_success\{collector="([^"]+)"\} 0$/;

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

// { VmHWM, VmRSS, VmData } in kB.
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

// Where the collectors' modules are: the source tree's beside the bench, or
// else the installed ones, as bench.uc finds the exporter.
const COLLECTORS = fs.realpath(`${fs.dirname(sourcepath())}/../../src/prometheus_exporter/collectors`) ?? loader.DIR;

// The collectors of a set, loaded as the exporter loads them: each module's
// text read and checked first (loader.refusal); with `probe`, each loaded in
// a child process first, as uhttpd loads them; then all of them as one
// program (loader.import_modules), or each alone with a revision of the
// exporter that has no import_modules (BENCH_REV).
function load_set(set, probe) {
	let names = sets[set] ?? die(`no set ${set}`);
	let out = [];

	for (let n in names) {
		let why = loader.refusal(fs.readfile(`${COLLECTORS}/${loader.id_of(n)}.uc`));

		if (why != null)
			die(`${n}: ${why}`);
	}

	let ids = map(names, loader.id_of);
	let probed = probe ? probe_modules(ids, loader.import_module) : {};

	for (let id in ids)
		if (probe && !probed[id]?.ok)
			die(`${id} did not load: ${probed[id]?.error}`);

	let together = loader.import_modules ? loader.import_modules(ids) : null;

	for (let id in ids) {
		let res = loader.validate(id, together ? together[id] : loader.import_module(id));

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
} else if (kind == 'load' || kind == 'probe') {
	let fds = length(fs.lsdir('/proc/self/fd') ?? []);

	mem_before = reset_peak();

	let t = now();
	result.collectors = length(load_set(arg, kind == 'probe'));
	result.time = now() - t;
	// The descriptors loading left open: ucode keeps the source of every
	// module it compiled open while the module lives.
	result.fds = length(fs.lsdir('/proc/self/fd') ?? []) - fds;
	result.rss_kb = memory().VmRSS;
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
} else if (kind == 'scrape' || kind == 'inline') {
	let t = now();
	let collectors = load_set(arg);
	let needs = [];
	let stats = {};

	result.load = now() - t;
	for (let c in collectors)
		push(needs, ...c.meta.needs);

	// The world's replies are read in the scrape, as a router's are made then.
	let mods = bench_world.modules(world, uniq(needs), { lazy: true });
	let env = {
		session: (to) => deps.session({ ...mods, log: to ?? log }), clock: () => clock(true), log, version: 'bench',
		fork: kind == 'scrape', stats, mkstemp: fs.mkstemp, readfile: fs.readfile,
	};

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
	// The child's own memory, and how much the scrape's process holds.
	result.children = stats.children;
	result.child_hwm_kb = stats.child?.VmHWM;
	result.child_data_kb = stats.child?.VmData;
	result.data_kb = memory().VmData;
} else if (kind == 'handler') {
	// The scrape as Prometheus gets it from the service: uhttpd running the
	// handler (handler.uc here, the service's with the world), which loads
	// the set's collectors when it starts; a request answered in a process
	// uhttpd forks, with the ledger, the progress file and the deadline; the
	// reply read back by wget. The first request fills the ledger, as the
	// first after a restart does; the second is timed.
	let names = sets[arg] ?? die(`no set ${arg}`);
	let base = `${world_dir}/../handler-${arg}`;
	let dir = `${base}/collectors`, state_dir = `${base}/state`;

	system(sprintf("rm -rf '%s' && mkdir -p '%s' '%s' && chmod 700 '%s'", base, dir, state_dir, state_dir));
	for (let n in names)
		fs.symlink(`${COLLECTORS}/${loader.id_of(n)}.uc`, `${dir}/${loader.id_of(n)}.uc`);

	let src = fs.realpath(`${fs.dirname(sourcepath())}/../../src`);
	let test = fs.realpath(`${fs.dirname(sourcepath())}/..`);
	let cfg = `${base}/handler.json`;

	fs.writefile(cfg, sprintf('%J', {
		search: [ `${test}/*.uc`, ...(src ? [ `${src}/*.uc` ] : []), '/usr/share/ucode/*.uc', '/usr/lib/ucode/*.so' ],
		world: world_dir, collectors: dir, state: state_dir,
	}));

	let started = now();
	let server = uhttpd.start(`${test}/bench/handler.uc`, cfg, `${base}/uhttpd.pid`);

	result.load = now() - started;
	if (!server.ok)
		die(server.error);

	let first = uhttpd.get(server.port, `${base}/reply`);

	if (first.status != '200 OK')
		die(`the first scrape answered ${first.status}`);

	let held = uhttpd.server(server.pid);

	// What asking costs, wget and the connection, which uhttpd answers itself
	// for a path no handler has: not what the service adds.
	let t = now();
	uhttpd.get(server.port, `${base}/reply`, '/none');
	result.client = now() - t;

	mem_before = reset_peak();

	t = now();
	let res = uhttpd.get(server.port, `${base}/reply`);
	result.time = now() - t;

	uhttpd.stop(server.pid);

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
	result.collectors = length(names);
	result.ok = res.status == '200 OK' && !length(failed);
	result.error = (res.status != '200 OK') ? `answered ${res.status}` : (length(failed) ? `failed: ${join(' ', failed)}` : null);
	// What Prometheus waits for besides the collectors: uhttpd, the
	// request's process, the scrape's and its children's work; not wget.
	result.collecting = collecting;
	result.outside = result.time - collecting - result.client;
	result.samples = samples(res.body);
	result.bytes = length(res.body);
	// The process uhttpd answers from, which holds every collector loaded.
	result.server_rss_kb = held.rss_kb;
	result.server_fds = held.fds;
} else if (kind == 'progress') {
	let names = sets[arg] ?? die(`no set ${arg}`);
	let dir = `${world_dir}/../state-progress`;

	fs.mkdir(dir, 0o700);

	let st = state.open(fs, dir, '1-1');

	mem_before = reset_peak();

	let t = now();
	let p = st.progress();

	for (let n in names)
		p.start(loader.id_of(n));
	p.collected();
	p.finish();
	result.time = now() - t;
	result.collectors = length(names);
	result.ok = !length(st.dead());
} else if (kind == 'auth') {
	// The check of a scrape's password, as the handler makes it before any
	// scrape: auth.allowed on the Authorization header Prometheus sends.
	// `cached` is a request after one that was let in, by the cache in the
	// state the earlier one left (the hash's, hash_password's, is not computed).
	let parts = split(arg, '@');
	let password = 'bench-secret';
	let header = 'Basic ' + b64enc(`prometheus:${password}`);
	let hash = (parts[0] == 'md5') ? crypt.md5_crypt(password, 'saltsalt')
		: crypt.sha_crypt((parts[0] == 'sha256') ? '5' : '6', password, 'saltsaltsaltsalt', +(parts[1] ?? auth.HASH_ROUNDS));
	let a = { user: 'prometheus', hash };
	let st = null;

	if (parts[0] == 'cached') {
		let dir = `${world_dir}/../state`;

		fs.mkdir(dir, 0o700);
		st = state.open(fs, dir, state.instance_id(fs));
		if (!auth.allowed(a, header, st) || st.read(auth.CACHE) != auth.digest(a, header))
			die('the cache keeps no entry');
	}

	mem_before = reset_peak();

	let t = now();
	result.ok = auth.allowed(a, header, st);
	result.time = now() - t;
	result.rounds = crypt.rounds(hash);
	result.cached = st != null;
} else if (kind == 'deadline') {
	let parts = split(arg, '@');
	let collectors = load_set(parts[0]);
	let needs = [];

	for (let c in collectors)
		push(needs, ...c.meta.needs);

	let mods = bench_world.modules(world, uniq(needs), { lazy: true, redirect: { '/proc/net/nf_conntrack': `${world_dir}/conntrack/${parts[1]}` } });
	let env = {
		session: (to) => deps.session({ ...mods, log: to ?? log }), clock: () => clock(true), log, version: 'bench',
		fork: true, mkstemp: fs.mkstemp, readfile: fs.readfile,
	};
	let dir = `${world_dir}/../state-deadline`;
	let timeout = 10;
	let budget = deadline.budget(timeout);

	fs.mkdir(dir, 0o700);

	// One instance for every run, as the scrapes of one uhttpd: its ledger
	// lasts from run to run, which a first scrape fills.
	let st = state.open(fs, dir, '1-1');

	if (st.read(ledger.NAME) == null) {
		let t = now();
		scrape.scrape(env, collectors, '', { deadline: t + budget, budget, state: st });
		result.first = now() - t;
	}

	mem_before = reset_peak();

	let t = now();
	let res = scrape.scrape(env, collectors, '', { deadline: t + budget, budget, state: st });
	result.time = now() - t;

	let left = [];
	for (let line in split(res.body, '\n')) {
		let m = match(line, FAILED);
		if (m)
			push(left, m[1]);
	}

	result.timeout = timeout;
	result.ok = res.status == '200 OK' && result.time < timeout;
	result.error = result.ok ? null : sprintf('%.2f s, past the %d s timeout', result.time, timeout);
	result.left_out = left;
	result.samples = samples(res.body);
	result.entries = +parts[1];
} else if (kind == 'ledger') {
	// A ledger of every collector of the set, after scrapes in which one of
	// them failed every time and another ran into the deadline, in the
	// state of this process's instance, as the handler's.
	let collectors = load_set(arg);
	let ids = map(collectors, (c) => c.id);
	let dir = `${world_dir}/../state-ledger`;
	let runs = map(collectors, (c, i) => ({
		id: c.id, name: c.meta.name, duration: 0.001 * (i + 1), samples: 10 * i, budget: 5,
		result: (i == 0) ? Result.err('SOURCE_INVALID', 'a failure of a few words') : ((i == 1) ? Result.err('SCRAPE_DEADLINE', 'killed') : Result.ok()),
	}));

	fs.mkdir(dir, 0o700);

	let st = state.open(fs, dir, state.instance_id(fs));
	let l = ledger.empty();

	for (let i = 0; i < 5; i++)
		l = ledger.record(l, runs, { seconds: 0.05, samples: 2000 }, ids);
	st.write(ledger.NAME, ledger.serialize(l));

	mem_before = reset_peak();

	let t = now();
	let read = ledger.parse(st.read(ledger.NAME));
	let order = ledger.order(read, collectors);

	st.update(ledger.NAME, (text) => ledger.serialize(ledger.record(ledger.parse(text), runs, { seconds: 0.05, samples: 2000 }, ids)));
	result.time = now() - t;
	result.ok = length(order) == length(collectors);
	result.collectors = length(collectors);
	result.bytes = length(st.read(ledger.NAME));
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
