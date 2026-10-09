/**
 * How a scrape's collectors run: one at a time, in the order a plan picks
 * them, each run handed back to the plan.
 *
 * forked(): in a child process forked from this one (ucode's uloop.task),
 * which has the collectors loaded already, so a fork costs no compiling. The
 * child goes through the plan itself, one collector after another, and
 * tells this process each one it starts; this process holds a timer on it.
 * A collector still running at its limit is stopped by killing the child,
 * and a new child runs the rest: so is one that never returns from a loop,
 * or waits in a system call (a FIFO opened with no writer, a socket that
 * never answers), which nothing inside a process could stop. A child that
 * dies under a collector (it ran past the memory limit, a native module
 * crashed, it called exit()) costs that collector, not the scrape. What a
 * collector logs, the child hands back with its run.
 *
 * uhttpd-mod-ucode's VM handles no signals: a ucode signal() handler is never
 * called there, and the signal's default action ends the request. A child
 * process, killed from outside, is what stops a collector there.
 *
 * inline(): in this process, for the tests: nothing stops a collector there.
 *
 * A plan is { next(log) -> job or null, started(job, pid), done(job, run) },
 * and goes through its collectors in an order of its own, the queue:
 * next() is called each time a collector can start, in the process it would
 * run in, and returns the next of the queue, or null when there is none; a
 * job it does not run is { c, skipped: its run }, and what it logs it logs
 * with `log`. started() is called in this process once the collector has
 * started, with the pid of the process it runs in. done() is called with
 * each job's run where next() gave the job, and again in this process,
 * where it is handed back: the queue then goes on after job.c, whatever
 * next() was asked there, so that a new child starts where the last one was
 * stopped. A job is
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
 * budget, text }: its families' names, and the text of them the reply holds
 * (prometheus_exporter.exposition's pack).
 *
 * env: { session(log) -> a deps session, clock() -> [ s, ns ] monotonic,
 *        log(level, msg), mkstemp, open, readfile: fs's (forked's), kill(pid): a
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
 * How soon a collector's limit must be, in seconds, for the child to tell
 * this process of its start at once, rather than leave it to be read at the
 * timer's next turn, which is at most POLL_MS away: twice that.
 *
 * @type {float}
 */
export const SOON = 2 * POLL_MS / 1000.0;

/**
 * The child tells this process of every WAKE-th collector it starts too, so
 * that it takes the runs before it while the child runs that one, rather
 * than all of them once the child is done: on a router of two cores, at
 * once. A message for each costs the two processes more than it saves.
 *
 * @type {int}
 */
export const WAKE = 4;

/**
 * A job, as the module's top comment says: what a plan's next() returns;
 * `skipped`, the run of a collector it does not run.
 *
 * @typedef {{
 *   c: Collector,
 *   cutoff: ?float,
 *   limit: ?float,
 *   at_deadline: boolean,
 *   budget: ?int,
 *   left: ?int,
 *   settings: ?Settings,
 *   view: ?ExporterView,
 *   skipped: ?Run
 * }} Job
 */

/**
 * A plan, as the module's top comment says: next(log), the next job or
 * null; started(job, pid), once a job's collector started; done(job, run),
 * each run handed back.
 *
 * @typedef {{
 *   next: (log: Log) => ?Job,
 *   started: ?function(Job, ?int): void,
 *   done: (job: Job, run: Run) => void
 * }} Plan
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
 * to run the collectors in ended twice in a row before running one. It is
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
 * The digits of a packed run's head's length, in hex.
 *
 * @type {int}
 */
export const HEAD_DIGITS = 8;

// The fields of a packed run's head, in their order: an array, which ucode
// makes and JSON writes and reads for less than an object, a table each.
const HEAD = [ 'name', 'id', 'samples', 'duration', 'budget', 'skipped', 'logs', 'ok', 'error', 'details', 'data', 'none', 'families', 'size' ];
const SIZE = index(HEAD, 'size');
// The fields of a collector's start's head (started()), which has no text.
const MARK = length([ 'id', 'limit', 'at_deadline', 'budget', 'started' ]);

/**
 * A run, and what was logged with it, as the child hands it over: the
 * length of its head (HEAD_DIGITS hex digits), its head, a line of JSON,
 * [ name, id, samples, duration, budget, skipped, logs, ok, error, details,
 * data, none, families, size ], its Result's fields without its prototype
 * and its families' names, and then its text, `size` bytes, as it is: JSON
 * would escape every quote of every label. One packed run follows another
 * in the file the child writes, which this process reads as the child goes.
 *
 * @param {Run} run the run, packed (its text written, its families' names
 *   alone, as exposition.pack leaves them).
 * @param {string[][]} logs what was logged with it: [ level, msg ] pairs.
 * @returns {string} the run, packed.
 */
export function pack(run, logs) {
	let res = run.result;
	let text = run.text ?? '';
	let head = sprintf('%J\n', [
		run.name, run.id, run.samples, run.duration, run.budget, run.skipped, logs,
		res.ok, res.error, res.details, res.data, res.none, run.families, length(text),
	]);

	return sprintf('%08x', length(head)) + head + text;
};

/**
 * A collector's start, as the child writes it before it runs it, in the
 * file its runs go to: [ id, limit, at_deadline, budget, started ], `started`
 * when it started (monotonic seconds), and no text.
 *
 * @param {Job} job its job.
 * @param {float} t when it started.
 * @returns {string} the start, packed.
 */
export function started(job, t) {
	let head = sprintf('%J\n', [ job.c.id, job.limit, job.at_deadline, job.budget, t ]);

	return sprintf('%08x', length(head)) + head;
};

/**
 * The run pack() wrote at `at` of `text`, and its logs: { run, logs, end },
 * `end` where the next one begins; or the start started() wrote there,
 * { start, end }, start its head; null where there is none, or only part of
 * one, as a child stopped while it wrote one leaves.
 *
 * @param {string} text what pack() and started() wrote, one after another.
 * @param {?int} at where the run begins; 0 when null.
 * @returns {?{ run: ?Run, logs: ?string[][], start: ?Array, end: int }} the
 *   run, its Result made one again, its logs, and where it ends; or the
 *   start.
 */
export function unpack(text, at) {
	at ??= 0;

	let n = hex(substr(text, at, HEAD_DIGITS));
	let start = at + HEAD_DIGITS + n;

	if (type(n) != 'int' || n <= 0 || start > length(text))
		return null;

	let h = null;

	try {
		h = json(substr(text, at + HEAD_DIGITS, n));
	} catch (e) {
		return null;
	}

	if (type(h) != 'array')
		return null;

	// A collector the child started.
	if (length(h) == MARK)
		return { start: h, end: start };

	if (type(h[SIZE]) != 'int' || start + h[SIZE] > length(text))
		return null;

	// run_one gives every failure its code: none is a run packed some other
	// way, never one the collector was killed in.
	let result = h[7]
		? ((h[11] != null) ? Result.none(h[11]) : Result.ok(h[10]))
		: Result.err(h[8] ?? errors.COLLECTOR_NO_RESULT, h[9], h[10]);

	return {
		run: {
			name: h[0], id: h[1], result, families: h[12] ?? [], samples: h[2], duration: h[3], budget: h[4],
			skipped: h[5], text: substr(text, start, h[SIZE]),
		},
		logs: h[6] ?? [],
		end: start + h[SIZE],
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

			for (let job = plan.next(env.log); job != null; job = plan.next(env.log)) {
				if (job.skipped) {
					plan.done(job, job.skipped);
					continue;
				}

				plan.started?.(job, null);
				plan.done(job, run_packed(env, run_fn, session, job, opts?.omit));
			}

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

// What the child runs: the plan, from where this process left it, until it
// has no more. Everything it needs it reads from `st`: uloop keeps the
// callbacks of every task it ran for as long as the process lives, and what
// they hold with them, so run() lets go of st's fields once it is done.
//
// Each run goes into st.out, a file this process made for this child before
// it forked it, appended (pack()), and so does each collector's start
// (started()), before it runs, with the run before it, in one write: so the
// runs it ran are there should it be stopped later. This process reads them
// as it goes, at its timer's turns (absorb), and holds a timer on the
// collector each start names. The pipe tells it of a collector whose limit
// is less than SOON away, which it could be past before that turn, of every
// WAKE-th, and of every one when this process has no reader of the file. A
// message must be no longer than PIPE_BUF (4096 bytes), as what ucode's
// uloop reads of the pipe without blocking: a longer one may be half there
// when this process reads it, and ucode then loses it whole.
function child_of(st) {
	return function(pipe) {
		let logs = [];
		let log = (level, msg) => push(logs, [ level, msg ]);
		let child_env = { ...st.env, log };
		let session = st.env.session(log);
		let out = st.out;
		let told = (st.reader == null), started_n = 0;
		// This process's pid, which a start gives the plan (the progress
		// file's line).
		let pid = int(split(st.env.readfile?.('/proc/self/stat') ?? '', ' ')[0]);

		if (type(pid) != 'int')
			pid = null;

		for (let job = st.plan.next(log); job != null; job = st.plan.next(log)) {
			let r = job.skipped;

			if (r == null) {
				let t = now(st.env);

				st.plan.started?.(job, pid);
				out.write(started(job, t));
				out.flush();
				if (told || (++started_n % WAKE) == 0 || (job.limit != null && job.limit - t < SOON))
					pipe.send({ start: [ job.c.id, job.limit, job.at_deadline, job.budget, t ] });
				r = run_packed(child_env, st.run_fn, session, job, st.omit);
			}

			st.plan.done(job, r);
			out.write(pack(r, logs));
			logs = [];
		}

		out.flush();
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
 * directory of the files the runs cross by (/tmp), a file a child, each
 * removed as soon as it is made, and gone with the scrape: on tmpfs, the
 * state's in the jail.
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
			let tmp = opts?.tmp ?? '/tmp';

			for (let c in opts?.collectors ?? [])
				by_id[c.id] = c;

			let st = {
				env, run_fn, by_id, plan, omit: opts?.omit, stats: opts?.stats,
				task: null, timer: null, gen: 0, job: null, started: null, done: false, lost: 0, out: null, reader: null, read_at: 0, ran: {},
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

			// A collector the child started, its start's head ([ id, limit,
			// at_deadline, budget, started ]): held by the timer, unless its
			// run is here already.
			function hold(s) {
				let c = st.by_id[s[0]];

				if (c == null || st.ran[c.id])
					return;

				st.job = { c, limit: s[1], at_deadline: s[2], budget: s[3] };
				st.started = s[4];
				// A child that started a collector is no failure to fork one.
				st.lost = 0;
			}

			// The runs the child wrote since this process last looked, handed
			// to the plan in the order it ran them, and what they logged
			// logged here, and the collector it started last held: how many
			// runs. The collector this process holds a timer on is done,
			// when its run is there. While the child runs, they are read by a
			// reader of their own (env.open), whose place in the file is not
			// the child's, which goes on writing: so this process takes the
			// runs while the child runs the next, on a router of two cores at
			// once. `last`: the child is done, and the file is read to its
			// end, and closed.
			function absorb(last) {
				let h = st.reader ?? (last ? st.out : null);
				let n = 0;

				if (h) {
					h.seek(st.read_at);

					let text = h.read('all') ?? '';
					let at = 0;

					for (let got = unpack(text, 0); got != null; got = unpack(text, got.end)) {
						at = got.end;
						if (got.start) {
							hold(got.start);
							continue;
						}

						let c = st.by_id[got.run.id];

						if (c == null)
							continue;

						for (let l in got.logs)
							st.env.log(l[0], l[1]);

						if (st.job?.c == c)
							st.job = null;

						st.ran[c.id] = true;
						st.plan.done({ c }, got.run);
						n++;
					}

					st.read_at += at;
				}

				if (last) {
					st.reader?.close();
					st.out?.close();
					st.reader = st.out = null;
				}

				return n;
			}

			function arm() {
				let ms = POLL_MS;

				if (st.job?.limit != null)
					ms = min(ms, max(0, int((st.job.limit - now(st.env)) * 1000)));

				st.timer.set(max(ms, 1));
			}

			// The child's end, or a collector it started that this process
			// is to hold sooner than its timer's next turn.
			function on_output(g, msg) {
				if (g != st.gen || st.done)
					return;

				if (msg?.end) {
					if (st.stats)
						st.stats.child = msg.memory;
					absorb(true);
					st.done = true;
					uloop.end();
					return;
				}

				if (type(msg?.start) != 'array')
					return;

				// The runs before it are written, and its start.
				absorb(false);
				hold(msg.start);
				arm();
			}

			function spawn() {
				let g = ++st.gen;

				st.job = null;
				st.out = env.mkstemp(`${tmp}/prometheus-exporter.XXXXXX`);

				if (!st.out)
					return fallback(`cannot make the file the collectors' runs cross by, in ${tmp}`);

				// The file is removed already: opened again through its
				// descriptor, it is read where the child does not write.
				st.read_at = 0;
				st.reader = st.env.open ? st.env.open(`/proc/self/fd/${st.out.fileno()}`, 'r') : null;
				st.task = uloop.task(child, (msg) => on_output(g, msg));

				if (!st.task) {
					absorb(true);
					return fallback('cannot fork a process to run the collectors in');
				}

				if (st.stats)
					st.stats.children = (st.stats.children ?? 0) + 1;
				arm();
			}

			function tick() {
				if (st.done)
					return;

				if (st.task.finished()) {
					let ran = absorb(true);

					if (st.job != null) {
						let r = killed(st.job, now(st.env) - st.started);

						log_stopped(st.env, r);
						finish(r);
						st.lost = 0;
						return spawn();
					}

					// It died before it ran a collector: once may be a passing
					// failure, twice in a row is not. The rest are not run,
					// which none of them did: their breakers stay as they are.
					if (ran == 0 && ++st.lost > 1) {
						let names = [];

						for (let job = st.plan.next(st.env.log); job != null; job = st.plan.next(st.env.log)) {
							if (job.skipped) {
								st.plan.done(job, job.skipped);
								continue;
							}

							push(names, job.c.meta.name);
							st.plan.done(job, not_run(job));
						}
						if (length(names))
							st.env.log('warning', `the processes forked to run the collectors in ended twice before running one; not run: ${join(', ', names)}`);
						st.done = true;
						return uloop.end();
					}

					if (ran > 0)
						st.lost = 0;

					return spawn();
				}

				// What it ran since the last turn, and the collector it runs.
				absorb(false);
				let took = (st.job != null) ? now(st.env) - st.started : 0;

				if (st.job?.limit != null && now(st.env) >= st.job.limit) {
					let r = cancelled(st.job, took);

					// What it started first, as the child's own end would
					// leave it running, its parent gone (env.kill).
					if (st.env.kill)
						st.env.kill(st.task.pid());
					st.task.kill();

					// What it ran before; and should the run it was stopped
					// in have been written as it was, that run.
					absorb(true);
					if (st.job != null) {
						log_stopped(st.env, r);
						finish(r);
					}

					return spawn();
				}

				arm();
			}

			uloop.init();
			st.timer = uloop.timer(POLL_MS, tick);
			spawn();

			if (!st.done)
				uloop.run();

			st.timer.cancel();
			uloop.done();
			st.reader?.close();
			st.out?.close();

			for (let k in [ 'env', 'run_fn', 'by_id', 'plan', 'task', 'timer', 'job', 'stats', 'out', 'reader', 'ran' ])
				st[k] = null;
			st.done = true;
		},
	};
};
