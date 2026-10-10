/**
 * How a scrape's collectors run: one at a time, in a plan's order.
 *
 * @module prometheus_exporter_runner
 */

'use strict';

import * as uloop from 'uloop';
import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as exposition from 'prometheus.exporter.exposition';
import { seconds } from 'prometheus.exporter.deadline';
import { POLL_MS } from 'prometheus.exporter.probe';

/** Seconds to a collector's limit under which the child tells of its start at once. */
export const SOON = 2 * POLL_MS / 1000.0;

/** The child tells this process of every WAKE-th collector it starts. */
export const WAKE = 4;

/** Bytes of untold runs after which the child tells of the next start. */
export const WAKE_BYTES = 16384;

/** Seconds a child holding no collector may run past the deadline. */
export const GRACE = POLL_MS / 1000.0;

/**
 * A job: what a plan's next() returns; `skipped` for one it does not run.
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
 * A plan: next(log), started(job, pid) and done(job, run).
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

function stopped(job, res, took) {
	return { name: job.c.meta.name, id: job.c.id, result: res, families: [], samples: 0, duration: took, budget: job.budget, text: '' };
}

/**
 * The run of a collector stopped at its budget's end or the deadline.
 *
 * @param {Job} job
 * @param {float} took
 * @returns {Run}
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
 * @param {Job} job
 * @param {float} took
 * @returns {Run}
 */
export function killed(job, took) {
	return stopped(job, Result.err(errors.COLLECTOR_KILLED,
		sprintf('its process ended while it ran, after %.2f s: out of memory, a crash, or exit()', took)), took);
};

/**
 * The run of a collector no child could be forked for.
 *
 * @param {Job} job
 * @returns {Run}
 */
export function not_run(job) {
	return { ...stopped(job, Result.err(errors.COLLECTOR_NOT_RUN,
		'not run: the processes forked to run the collectors in ended twice before running one'), 0), skipped: 'runner' };
};

/**
 * The run of a collector left out at the deadline after its child was stopped.
 *
 * @param {Job} job
 * @returns {Run}
 */
export function late(job) {
	return { ...stopped(job, Result.err(errors.SCRAPE_DEADLINE, 'not run: the scrape\'s time was spent'), 0), skipped: 'deadline' };
};

/** The digits of a packed run's head's length, in hex. */
export const HEAD_DIGITS = 8;

const HEAD = [ 'name', 'id', 'samples', 'duration', 'budget', 'skipped', 'logs', 'ok', 'error', 'details', 'data', 'none', 'families', 'size' ];
const SIZE = index(HEAD, 'size');
const NUMBER = [ 'int', 'double' ];
const MARK = length([ 'id', 'limit', 'at_deadline', 'budget', 'started' ]);

/**
 * A run and its logs, packed as the child hands them over.
 *
 * @param {Run} run
 * @param {string[][]} logs
 * @returns {string}
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
 * A collector's start, as the child writes it before it runs it.
 *
 * @param {Job} job
 * @param {float} t
 * @returns {string}
 */
export function started(job, t) {
	let head = sprintf('%J\n', [ job.c.id, job.limit, job.at_deadline, job.budget, t ]);

	return sprintf('%08x', length(head)) + head;
};

/**
 * The run, or start, written at `at` of `text`, and where the next begins.
 *
 * @param {string} text
 * @param {?int} at
 * @returns {?{ run: ?Run, logs: ?string[][], start: ?Array, end: int }}
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

	if (length(h) == MARK)
		return { start: h, end: start };

	if (type(h[SIZE]) != 'int' || start + h[SIZE] > length(text))
		return null;

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

function run_packed(env, run_fn, session, job, omit) {
	let r = run_fn(env, session, job.c, job);
	let p = exposition.pack(r.families, omit);

	r.families = p.families;
	r.text = p.text;
	return r;
}

function log_stopped(env, r) {
	if (r.result.error != errors.SCRAPE_DEADLINE)
		env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
}

/**
 * The runner in this process, for the tests: nothing stops a collector.
 *
 * @param {ScrapeEnv} env
 * @param {RunFn} run_fn
 * @param {?{ omit: ?boolean }} opts
 * @returns {Runner}
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
 *
 * @param {function(string): ?string} readfile
 * @returns {Object<string, int>}
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

function child_of(st) {
	return function(pipe) {
		let logs = [];
		let log = (level, msg) => push(logs, [ level, msg ]);
		let child_env = { ...st.env, log };
		let session = st.env.session(log);
		let out = st.out;
		let told = (st.reader == null), started_n = 0, pending = 0;
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
				if (told || (++started_n % WAKE) == 0 || pending >= WAKE_BYTES || (job.limit != null && job.limit - t < SOON)) {
					pipe.send({ start: [ job.c.id, job.limit, job.at_deadline, job.budget, t ] });
					pending = 0;
				}
				r = run_packed(child_env, st.run_fn, session, job, st.omit);
			}

			let text = pack(r, logs);

			st.plan.done(job, r);
			out.write(text);
			pending += length(text);
			logs = [];
		}

		out.flush();
		session.close();
		return { end: true, memory: st.stats ? memory(st.env.readfile) : null };
	};
}

/**
 * The runner in a forked child, stopped at a collector's limit or the deadline.
 *
 * @param {ScrapeEnv} env
 * @param {RunFn} run_fn
 * @param {?{ collectors: ?Collector[], omit: ?boolean, stats: ?Object, tmp: ?string, deadline: ?float }} opts
 * @returns {Runner}
 */
export function forked(env, run_fn, opts) {
	return {
		run: function(plan) {
			let by_id = {};
			let tmp = opts?.tmp ?? '/tmp';
			let deadline = opts?.deadline;

			for (let c in opts?.collectors ?? [])
				by_id[c.id] = c;

			let st = {
				env, run_fn, by_id, plan, omit: opts?.omit, stats: opts?.stats,
				task: null, timer: null, gen: 0, job: null, started: null, done: false, lost: 0, out: null, reader: null, read_at: 0, ran: {},
			};
			let child = child_of(st);

			function fallback(why) {
				st.env.log('warning', `${why}; running the collectors in the scrape's own process`);
				inline(st.env, st.run_fn, { omit: st.omit }).run(st.plan);
				st.done = true;
				if (st.timer)
					uloop.end();
			}

			function finish(job, r) {
				if (st.job?.c == job.c)
					st.job = null;
				st.plan.done(job, r);
			}

			function stop_child() {
				if (st.task == null || st.task.finished())
					return;
				if (st.env.kill)
					st.env.kill(st.task.pid());
				st.task.kill();
			}

			function hold(s) {
				let c = st.by_id[s[0]];

				if (c == null || st.ran[c.id])
					return;

				let limit = s[1], t = s[4];

				st.job = { c, limit: (type(limit) in NUMBER) ? limit : null, at_deadline: s[2], budget: s[3] };
				st.started = (type(t) in NUMBER) ? t : now(st.env);
				st.lost = 0;
			}

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

			function due(t) {
				let limit = st.job?.limit;

				if (deadline == null)
					return limit;
				if (st.job != null)
					return (limit != null && limit < deadline) ? limit : deadline;

				return (t < deadline) ? deadline : deadline + GRACE;
			}

			function arm() {
				let ms = POLL_MS;
				let t = now(st.env);
				let at = due(t);

				if (at != null)
					ms = min(ms, max(0, int((at - t) * 1000)));

				st.timer.set(max(ms, 1));
			}

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

			function backstop() {
				stop_child();
				absorb(true);
				if (st.job != null)
					finish(st.job, cancelled({ ...st.job, at_deadline: true }, now(st.env) - st.started));

				st.env.log('warning', 'the process running the collectors ran past the scrape\'s deadline, past the limits it gave: stopped there, the rest left out');
				for (let job = st.plan.next(st.env.log); job != null; job = st.plan.next(st.env.log))
					st.plan.done(job, job.skipped ?? late(job));
				st.done = true;
				uloop.end();
			}

			function tick() {
				if (st.done)
					return;

				if (st.task.finished()) {
					let ran = absorb(true);

					if (st.job != null) {
						let r = killed(st.job, now(st.env) - st.started);

						log_stopped(st.env, r);
						finish(st.job, r);
						st.lost = 0;
						return spawn();
					}

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

				absorb(false);
				let t = now(st.env);
				let limit = st.job?.limit;

				if (limit != null && t >= limit && (deadline == null || limit <= deadline)) {
					let job = st.job, took = t - st.started;

					stop_child();
					absorb(true);
					if (!st.ran[job.c.id]) {
						let r = cancelled(job, took);

						log_stopped(st.env, r);
						finish(job, r);
					}

					return spawn();
				}

				if (deadline != null && t >= due(t))
					return backstop();

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
