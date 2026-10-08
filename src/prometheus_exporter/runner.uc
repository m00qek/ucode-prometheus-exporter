/**
 * How a scrape's collectors run: one at a time, in the order a plan picks
 * them, each run handed back to the plan.
 *
 * forked(): in a child process forked from this one (ucode's uloop.task),
 * which has the collectors loaded already, so a fork costs no compiling. The
 * child runs them one after another, asking this process for each; this
 * process holds a timer on each. A collector still running at its limit is
 * stopped by killing the child, and a new child runs the rest: so is one that
 * never returns from a loop, or waits in a system call (a FIFO opened with no
 * writer, a socket that never answers), which nothing inside a process could
 * stop. A child that dies under a collector (it ran past the memory limit, a
 * native module crashed, it called exit()) costs that collector, not the
 * scrape. What a collector logs, the child sends back with its run.
 *
 * uhttpd-mod-ucode's VM handles no signals: a ucode signal() handler is never
 * called there, and the signal's default action ends the request. A child
 * process, killed from outside, is what stops a collector there.
 *
 * inline(): in this process, for the tests: nothing stops a collector there.
 *
 * A plan is { next(pid) -> job or null, done(job, run) }. next() is called
 * each time a collector can start, with the pid of the process it would run
 * in: it returns the next to run, or null when there is none, and leaves out
 * (and hands done) any it does not run. A job is
 * { c, cutoff, limit, at_deadline, budget, left, settings, view }:
 *   c            the collector
 *   cutoff       when its programs must be done by (monotonic seconds), or null
 *   limit        when it is stopped (monotonic seconds), or null for never:
 *                its budget's end, or the cutoff when that comes first
 *   at_deadline  whether the limit is the cutoff
 *   budget       the seconds it may take (config.settings)
 *   left         the samples left of the reply's max_scrape_samples, or null
 *   settings     config.settings' data, or null to read them in the run
 *   view         the exporter collector's data (deps.exporter_channel)
 * A run is scrape.run_one's: { name, id, result, families, samples, duration,
 * budget, text }: its families' names and types, and the text of them the
 * reply holds (prometheus_exporter.exposition's pack).
 *
 * env: { session(log) -> a deps session, clock() -> [ s, ns ] monotonic,
 *        log(level, msg), mkstemp, readfile: fs's (forked's), kill(pid): a
 *        child it stops, killed with every process under it (forked's) };
 * run_fn(env, session, c, job) -> a run.
 *
 * @module prometheus_exporter_runner
 */

'use strict';

import * as uloop from 'uloop';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as exposition from 'prometheus_exporter.exposition';
import { seconds } from 'prometheus_exporter.deadline';
import { POLL_MS } from 'prometheus_exporter.probe';

/**
 * A job, as the module's top comment says: what a plan's next() returns.
 *
 * @typedef {{
 *   c: Collector,
 *   cutoff: ?float,
 *   limit: ?float,
 *   at_deadline: boolean,
 *   budget: ?int,
 *   left: ?int,
 *   settings: ?Settings,
 *   view: ?ExporterView
 * }} Job
 */

/**
 * A plan, as the module's top comment says: next(pid), the next job or
 * null; done(job, run), each run handed back.
 *
 * @typedef {{ next: (pid: ?int) => ?Job, done: (job: Job, run: Run) => void }} Plan
 */

/**
 * A runner, inline()'s or forked()'s: run(plan) runs a plan's collectors.
 *
 * @typedef {{ run: (plan: Plan) => void }} Runner
 */

/**
 * What runs one collector: scrape.run_one, or a test's.
 *
 * @typedef {(env: ScrapeEnv, session: Session, c: Collector, job: ?Job) => Run} RunFn
 */

function now(env) {
	return seconds(env.clock());
}

// The run of a collector stopped from outside, which wrote nothing.
function stopped(job, res, took) {
	return { name: job.c.meta.name, id: job.c.id, result: res, families: [], samples: 0, duration: took, budget: job.budget, text: '' };
}

/**
 * The run of a collector stopped at its limit: its budget's end, or the
 * scrape's deadline. One at the deadline is SCRAPE_DEADLINE, as a program
 * killed there is: the scrape's time was spent, not the collector's budget.
 *
 * @param {Job} job its job.
 * @param {float} took the seconds it ran.
 * @returns {Run} the run: SCRAPE_DEADLINE or COLLECTOR_CANCELLED.
 */
export function cancelled(job, took) {
	if (job.at_deadline)
		return stopped(job, Result.err(errors.SCRAPE_DEADLINE,
			sprintf('still running at the scrape\'s deadline, after %.2f s: stopped', took), { deadline: true }), took);

	return stopped(job, Result.err(errors.COLLECTOR_CANCELLED,
		sprintf('still running after %.2f s, over its budget of %d s: stopped', took, job.budget)), took);
};

/**
 * The run of a collector whose process ended under it.
 *
 * @param {Job} job its job.
 * @param {float} took the seconds it ran.
 * @returns {Run} the run: COLLECTOR_KILLED.
 */
export function killed(job, took) {
	return stopped(job, Result.err(errors.COLLECTOR_KILLED,
		sprintf('its process ended while it ran, after %.2f s: out of memory, a crash, or exit()', took)), took);
};

/**
 * The run of a collector no process could be started for: the children forked
 * to run the collectors in ended twice in a row before asking for one. It is
 * not the collector's doing, so it is left out, as one the deadline leaves
 * out is (`skipped`), which leaves its breaker as it was.
 *
 * @param {Job} job its job.
 * @returns {Run} the run: COLLECTOR_NOT_RUN.
 */
export function not_run(job) {
	return { ...stopped(job, Result.err(errors.COLLECTOR_NOT_RUN,
		'not run: the processes forked to run the collectors in ended twice before running one'), 0), skipped: 'runner' };
};

/**
 * A run, and what was logged with it, as the child hands it over: a line of
 * JSON, { name, id, result, samples, duration, budget, logs, families: [
 * { name, type } ] }, its Result without its prototype, and then its text,
 * as it is: JSON would escape every quote of every label. The families go as
 * they are, which JSON writes and reads in C: a scrape's are hundreds, and a
 * function called on each, here and in unpack(), cost more than the rest.
 *
 * @param {Run} run the run, packed (its text written, its families' names
 *   and types alone, as exposition.pack leaves them).
 * @param {string[][]} logs what was logged with it: [ level, msg ] pairs.
 * @returns {string} the line of JSON and the text.
 */
export function pack(run, logs) {
	let res = run.result;
	let head = {
		name: run.name, id: run.id, samples: run.samples, duration: run.duration, budget: run.budget, logs,
		result: { ok: res.ok, error: res.error, details: res.details, data: res.data, none: res.none },
		families: run.families,
	};

	return sprintf('%J\n', head) + run.text;
};

/**
 * The run of pack()'s text, and its logs: { run, logs }.
 *
 * @param {string} text pack()'s text.
 * @returns {{ run: Run, logs: string[][] }} the run, its Result made one
 *   again, and its logs.
 */
export function unpack(text) {
	let nl = index(text, '\n');
	let head = json(substr(text, 0, nl));
	let res = head.result ?? {};
	let families = head.families ?? [];

	// run_one gives every failure its code: none is a run packed some other
	// way, never one the collector was killed in.
	let result = res.ok
		? ((res.none != null) ? Result.none(res.none) : Result.ok(res.data))
		: Result.err(res.error ?? errors.COLLECTOR_NO_RESULT, res.details, res.data);

	return {
		run: {
			name: head.name, id: head.id, result, families, samples: head.samples, duration: head.duration, budget: head.budget,
			text: substr(text, nl + 1),
		},
		logs: head.logs ?? [],
	};
};

// The run of `job`, its families written as its text, with `omit`
// (omit_zero_values): exposition.pack.
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

/**
 * The runner in this process, for the tests: each job's collector run
 * here, one after another; nothing stops a collector.
 *
 * @param {ScrapeEnv} env the scrape's env.
 * @param {RunFn} run_fn what runs one collector.
 * @param {?{ omit: ?boolean }} opts omit: omit_zero_values.
 * @returns {Runner} the runner.
 */
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

/**
 * This process's memory, in kB: { VmHWM, VmData, VmRSS }, for the benchmark.
 * readfile: fs's.
 *
 * @param {function(string): ?string} readfile fs's readfile.
 * @returns {Object<string, int>} VmHWM, VmData and VmRSS, in kB.
 */
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

/**
 * The runner in a child process forked from this one, as the module's top
 * comment says: a collector still running at its limit is stopped with the
 * process, and a new child runs the rest.
 *
 * opts: { collectors: every collector a plan may pick, omit, stats, tmp }.
 * stats, when given, is an object it fills in: children, how many it forked;
 * child, the memory of the last that ran to its end (memory()). tmp: the
 * directory of the file the runs cross by (/tmp), which is removed as soon as
 * it is made, and gone with the scrape: on tmpfs, the state's in the jail.
 *
 * @param {ScrapeEnv} env the scrape's env.
 * @param {RunFn} run_fn what runs one collector.
 * @param {?{ collectors: ?Collector[], omit: ?boolean, stats: ?Object, tmp: ?string }} opts
 *   the options.
 * @returns {Runner} the runner.
 */
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
			// memory), or the file the runs cross by cannot be made, the rest
			// run here, unguarded, rather than not at all; `why` says which.
			function fallback(why) {
				st.env.log('warning', `${why}; running the collectors in the scrape's own process`);
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

				return { id: job.c.id, cutoff: job.cutoff, limit: job.limit, left: job.left, settings: job.settings, view: job.view };
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

				// A child that ran a collector is no failure to fork one.
				st.lost = 0;
				finish(got.run);
			}

			function spawn() {
				let g = ++st.gen;

				st.closing = false;
				st.task = uloop.task(child, (msg) => on_output(g, msg), () => on_input(g));

				if (!st.task)
					return fallback('cannot fork a process to run the collectors in');

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
					// passing failure, twice in a row is not. The rest are not
					// run, which none of them did: their breakers stay as they are.
					if (++st.lost > 1) {
						let names = [];

						for (let job = st.plan.next(); job != null; job = st.plan.next()) {
							st.job = job;
							push(names, job.c.meta.name);
							finish(not_run(job));
						}
						if (length(names))
							st.env.log('warning', `the processes forked to run the collectors in ended twice before running one; not run: ${join(', ', names)}`);
						st.done = true;
						return uloop.end();
					}

					return spawn();
				}

				if (st.job?.limit != null && now(st.env) >= st.job.limit) {
					let r = cancelled(st.job, took);

					// What it started first, as the child's own end would
					// leave it running, its parent gone (env.kill).
					if (st.env.kill)
						st.env.kill(st.task.pid());
					st.task.kill();
					log_stopped(st.env, r);
					finish(r);
					return spawn();
				}

				arm();
			}

			let tmp = opts?.tmp ?? '/tmp';

			st.out = env.mkstemp(`${tmp}/prometheus-exporter.XXXXXX`);

			if (!st.out)
				return fallback(`cannot make the file the collectors' runs cross by, in ${tmp}`);

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
