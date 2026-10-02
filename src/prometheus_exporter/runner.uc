'use strict';

// How a scrape's collectors run: one at a time, in the order a plan picks
// them, each run handed back to the plan.
//
// forked(): in a child process forked from this one (ucode's uloop.task),
// which has the collectors loaded already, so a fork costs no compiling. The
// child runs them one after another, asking this process for each; this
// process holds a timer on each. A collector still running at its limit is
// stopped by killing the child, and a new child runs the rest: so is one that
// never returns from a loop, or waits in a system call (a FIFO opened with no
// writer, a socket that never answers), which nothing inside a process could
// stop. A child that dies under a collector (it ran past the memory limit, a
// native module crashed, it called exit()) costs that collector, not the
// scrape. What a collector logs, the child sends back with its run.
//
// uhttpd-mod-ucode's VM handles no signals: a ucode signal() handler is never
// called there, and the signal's default action ends the request. A child
// process, killed from outside, is what stops a collector there.
//
// inline(): in this process, for the tests: nothing stops a collector there.
//
// A plan is { next(pid) -> job or null, done(job, run) }. next() is called
// each time a collector can start, with the pid of the process it would run
// in: it returns the next to run, or null when there is none, and leaves out
// (and hands done) any it does not run. A job is
// { c, cutoff, limit, at_deadline, budget, settings, view }:
//   c            the collector
//   cutoff       when its programs must be done by (monotonic seconds), or null
//   limit        when it is stopped (monotonic seconds), or null for never:
//                its budget's end, or the cutoff when that comes first
//   at_deadline  whether the limit is the cutoff
//   budget       the seconds it may take (config.settings)
//   settings     config.settings' data, or null to read them in the run
//   view         the exporter collector's data (deps.exporter_channel)
// A run is scrape.run_one's: { name, id, result, families, samples, duration,
// budget, text }: its families' names and types, and the text of them the
// reply holds (prometheus_exporter.exposition's pack).
//
// env: { session(log) -> a deps session, clock() -> [ s, ns ] monotonic,
//        log(level, msg), mkstemp, readfile: fs's (forked's) };
// run_fn(env, session, c, job) -> a run.

import * as uloop from 'uloop';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as exposition from 'prometheus_exporter.exposition';
import { seconds } from 'prometheus_exporter.deadline';

// How often this process looks whether the child is still there, while a
// collector runs: a child that died is noticed within this many
// milliseconds. Each look is a timer's wakeup, a few microseconds.
export const POLL_MS = 100;

function now(env) {
	return seconds(env.clock());
}

// The run of a collector stopped from outside, which wrote nothing.
function stopped(job, res, took) {
	return { name: job.c.meta.name, id: job.c.id, result: res, families: [], samples: 0, duration: took, budget: job.budget, text: '' };
}

// The run of a collector stopped at its limit: its budget's end, or the
// scrape's deadline. One at the deadline is SCRAPE_DEADLINE, as a program
// killed there is: the scrape's time was spent, not the collector's budget.
export function cancelled(job, took) {
	if (job.at_deadline)
		return stopped(job, Result.err(errors.SCRAPE_DEADLINE,
			sprintf('still running at the scrape\'s deadline, after %.2f s: stopped', took), { deadline: true }), took);

	return stopped(job, Result.err(errors.COLLECTOR_CANCELLED,
		sprintf('still running after %.2f s, over its budget of %d s: stopped', took, job.budget)), took);
};

// The run of a collector whose process ended under it.
export function killed(job, took) {
	return stopped(job, Result.err(errors.COLLECTOR_KILLED,
		sprintf('its process ended while it ran, after %.2f s: out of memory, a crash, or exit()', took)), took);
};

// A run, and what was logged with it, as the child hands it over: a line of
// JSON, { name, id, result, samples, duration, budget, logs, families: [
// [ name, type ] ] }, its Result without its prototype, and then its text,
// as it is: JSON would escape every quote of every label.
export function pack(r, logs) {
	let res = r.result;
	let head = {
		name: r.name, id: r.id, samples: r.samples, duration: r.duration, budget: r.budget, logs,
		result: { ok: res.ok, error: res.error, details: res.details, data: res.data, none: res.none },
		families: map(r.families, (f) => [ f.name, f.type ]),
	};

	return sprintf('%J\n', head) + r.text;
};

// The run of pack()'s text, and its logs: { run, logs }.
export function unpack(text) {
	let nl = index(text, '\n');
	let head = json(substr(text, 0, nl));
	let res = head.result ?? {};
	let families = map(head.families ?? [], (f) => ({ name: f[0], type: f[1] }));

	let result = res.ok
		? ((res.none != null) ? Result.none(res.none) : Result.ok(res.data))
		: Result.err(res.error ?? errors.COLLECTOR_KILLED, res.details, res.data);

	return {
		run: {
			name: head.name, id: head.id, result, families, samples: head.samples, duration: head.duration, budget: head.budget,
			text: substr(text, nl + 1),
		},
		logs: head.logs ?? [],
	};
};

// The run of `job`, its families packed with `omit` (omit_zero_values).
function run_packed(env, run_fn, session, job, omit) {
	let r = run_fn(env, session, job.c, job);
	let p = exposition.pack(r.families, omit);

	r.families = p.families;
	r.text = p.text;
	return r;
}

// Logs what stopping a run says, as run_one logs a failure: but for
// SCRAPE_DEADLINE, which the scrape says in one line.
function log_stopped(env, r) {
	if (r.result.error != errors.SCRAPE_DEADLINE)
		env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
}

export function inline(env, run_fn, opts) {
	return {
		run: function(plan) {
			let session = env.session();

			for (let job = plan.next(); job != null; job = plan.next())
				plan.done(job, run_packed(env, run_fn, session, job, opts?.omit));

			session.close();
		},
	};
};

const STATUS = /^(VmHWM|VmData|VmRSS):\s+([0-9]+) kB/;

// This process's memory, in kB: { VmHWM, VmData, VmRSS }, for the benchmark.
// readfile: fs's.
export function memory(readfile) {
	let m = {};

	for (let line in split(readfile('/proc/self/status') ?? '', '\n')) {
		let f = match(line, STATUS);

		if (f)
			m[f[1]] = +f[2];
	}

	return m;
};

// What the child runs: the jobs this process sends, until it sends none.
// Everything it needs it reads from `st`: uloop keeps the callbacks of every
// task it ran for as long as the process lives, and what they hold with them,
// so run() lets go of st's fields once it is done.
//
// Each run goes into st.out, a file this process made before it forked the
// child, which they share, appended (pack()); the pipe carries where it is.
// A message the child sends must be no longer than PIPE_BUF (4096 bytes), as
// what ucode's uloop reads of the pipe without blocking: a longer one may be
// half there when this process reads it, and ucode then loses it whole.
function child_of(st) {
	return function(pipe) {
		let logs = [];
		let log = (level, msg) => push(logs, [ level, msg ]);
		let child_env = { ...st.env, log };
		let session = st.env.session(log);

		for (let job = pipe.receive(); job?.id != null; job = pipe.receive()) {
			logs = [];

			let r = run_packed(child_env, st.run_fn, session, { ...job, c: st.by_id[job.id] }, st.omit);
			let text = pack(r, logs);

			st.out.seek(0, 2);

			let at = st.out.tell();

			st.out.write(text);
			st.out.flush();
			pipe.send({ id: r.id, at, size: length(text) });
		}

		session.close();
		return { end: true, memory: st.stats ? memory(st.env.readfile) : null };
	};
}

// opts: { collectors: every collector a plan may pick, omit, stats, tmp }.
// stats, when given, is an object it fills in: children, how many it forked;
// child, the memory of the last that ran to its end (memory()). tmp: the
// directory of the file the runs cross by (/tmp), which is removed as soon as
// it is made, and gone with the scrape: on tmpfs, the state's in the jail.

export function forked(env, run_fn, opts) {
	return {
		run: function(plan) {
			let by_id = {};

			for (let c in opts?.collectors ?? [])
				by_id[c.id] = c;

			let st = {
				env, run_fn, by_id, plan, omit: opts?.omit, stats: opts?.stats,
				task: null, timer: null, gen: 0, job: null, started: null, closing: false, done: false, lost: 0,
			};
			let child = child_of(st);

			// When no child can be forked (the system is out of processes or
			// memory), the rest run here, unguarded, rather than not at all.
			function fallback() {
				st.env.log('warning', 'cannot fork a process to run the collectors in; running them in the scrape\'s own');
				inline(st.env, st.run_fn, { omit: st.omit }).run(st.plan);
				st.done = true;
				if (st.timer)
					uloop.end();
			}

			function finish(r) {
				let job = st.job;

				st.job = null;
				st.plan.done(job, r);
			}

			function arm() {
				let ms = POLL_MS;

				if (st.job?.limit != null)
					ms = min(ms, max(0, int((st.job.limit - now(st.env)) * 1000)));

				st.timer.set(max(ms, 1));
			}

			function on_input(g) {
				if (g != st.gen || st.done)
					return null;

				let job = st.plan.next(st.task?.pid());

				if (job == null) {
					st.closing = true;
					return null;
				}

				st.job = job;
				st.started = now(st.env);
				arm();

				return { id: job.c.id, cutoff: job.cutoff, limit: job.limit, settings: job.settings, view: job.view };
			}

			function on_output(g, msg) {
				if (g != st.gen || st.done)
					return;

				if (msg?.end) {
					if (st.stats)
						st.stats.child = msg.memory;
					st.done = true;
					uloop.end();
					return;
				}

				if (st.job == null || msg?.id != st.job.c.id)
					return;

				st.out.seek(msg.at);

				let got = unpack(st.out.read(msg.size));

				for (let l in got.logs)
					st.env.log(l[0], l[1]);

				finish(got.run);
			}

			function spawn() {
				let g = ++st.gen;

				st.closing = false;
				st.task = uloop.task(child, (msg) => on_output(g, msg), () => on_input(g));

				if (!st.task)
					return fallback();

				if (st.stats)
					st.stats.children = (st.stats.children ?? 0) + 1;
				arm();
			}

			function tick() {
				if (st.done)
					return;

				let took = (st.job != null) ? now(st.env) - st.started : 0;

				if (st.task.finished()) {
					if (st.job != null) {
						let r = killed(st.job, took);

						log_stopped(st.env, r);
						finish(r);
						st.lost = 0;
						return spawn();
					}

					if (st.closing) {
						st.done = true;
						return uloop.end();
					}

					// It died before it asked for a collector: once may be a
					// passing failure, twice is not.
					if (++st.lost > 1) {
						for (let job = st.plan.next(); job != null; job = st.plan.next()) {
							st.job = job;
							finish(killed(job, 0));
						}
						st.done = true;
						return uloop.end();
					}

					return spawn();
				}

				if (st.job?.limit != null && now(st.env) >= st.job.limit) {
					let r = cancelled(st.job, took);

					st.task.kill();
					log_stopped(st.env, r);
					finish(r);
					return spawn();
				}

				arm();
			}

			st.out = env.mkstemp(`${opts?.tmp ?? '/tmp'}/prometheus-exporter.XXXXXX`);

			if (!st.out)
				return fallback();

			uloop.init();
			st.timer = uloop.timer(POLL_MS, tick);
			spawn();

			if (!st.done)
				uloop.run();

			st.timer.cancel();
			uloop.done();
			st.out.close();

			for (let k in [ 'env', 'run_fn', 'by_id', 'plan', 'task', 'timer', 'job', 'stats', 'out' ])
				st[k] = null;
			st.done = true;
		},
	};
};

// The seconds a collector module may take to load. Its top level declares
// what it exports and little else: loading every collector the packages have
// takes the devenv 46 ms (load:full in the benchmark), about 1.5 ms a module,
// and a 500-MIPS MIPS router about forty times that. Five seconds is a
// hundred times what the largest takes there, and still what a router starts
// uhttpd in, should one never finish.
export const LOAD_TIMEOUT = 5;

// Each of the modules `ids` loaded with import_fn(id) (loader.import_module)
// in a child process first, as a scrape's collectors run (forked()): one that
// does not load within `seconds` (LOAD_TIMEOUT) is stopped with its process,
// and a new one loads the rest. { <id>: { ok, error, hung, seconds } }: error,
// the first line of what loading it threw; hung, whether it was stopped.
// clock_fn: [ s, ns ], monotonic.
//
// Only what loads here is then loaded in the process that serves the scrapes:
// a module whose top level never returns would keep uhttpd from ever serving.
// Each module is so compiled twice, once here and once there.
export function probe(ids, import_fn, seconds, clock_fn) {
	let out = {};
	let left = [ ...ids ];
	let env = { clock: clock_fn ?? (() => clock(true)) };
	let st = { import_fn, task: null, gen: 0, id: null, started: null, done: false, lost: 0 };
	let timer = null;

	seconds ??= LOAD_TIMEOUT;

	if (!length(ids))
		return out;

	// Loading a module keeps it, and its source open, while anything holds
	// it: the child drops each, and this process never has them.
	function child(pipe) {
		for (let id = pipe.receive(); type(id) == 'string'; id = pipe.receive()) {
			let error = null;

			try {
				st.import_fn(id);
			} catch (e) {
				error = substr(split(e.message, '\n')[0], 0, 1024);
			}

			// No longer than PIPE_BUF, as child_of says.
			pipe.send({ id, error });
		}

		return { end: true };
	}

	function finish(res) {
		out[st.id] = { ...res, seconds: now(env) - st.started };
		st.id = null;
	}

	function on_input(g) {
		if (g != st.gen || !length(left))
			return null;

		st.id = shift(left);
		st.started = now(env);
		timer.set(POLL_MS);
		return st.id;
	}

	function on_output(g, msg) {
		if (g != st.gen)
			return;

		if (msg?.end) {
			st.done = true;
			return uloop.end();
		}

		if (msg?.id == st.id)
			finish({ ok: msg.error == null, error: msg.error, hung: false });
	}

	function spawn() {
		let g = ++st.gen;

		st.task = uloop.task(child, (msg) => on_output(g, msg), () => on_input(g));

		// No child: each loads here, as before there was one.
		if (!st.task) {
			for (let id in left)
				out[id] = { ok: true, error: null, hung: false, seconds: 0, unprobed: true };
			left = [];
			st.done = true;
			return uloop.end();
		}

		timer.set(POLL_MS);
	}

	function tick() {
		if (st.done)
			return;

		if (st.task.finished()) {
			if (st.id != null)
				finish({ ok: false, error: 'its process ended while it loaded', hung: false });
			else if (!length(left) || ++st.lost > 1) {
				for (let id in left)
					out[id] = { ok: false, error: 'no process could load it', hung: false, seconds: 0 };
				st.done = true;
				return uloop.end();
			}

			return spawn();
		}

		if (st.id != null && now(env) - st.started >= seconds) {
			st.task.kill();
			finish({ ok: false, error: `still loading after ${seconds} s: stopped`, hung: true });
			return spawn();
		}

		timer.set(POLL_MS);
	}

	uloop.init();
	timer = uloop.timer(POLL_MS, tick);
	spawn();

	if (!st.done)
		uloop.run();

	timer.cancel();
	uloop.done();
	st.import_fn = null;
	st.task = null;
	st.done = true;

	return out;
};
