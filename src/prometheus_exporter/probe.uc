/**
 * The load probe: collector modules loaded in a child process first, as a
 * scrape's collectors run (prometheus_exporter.runner), so that only what
 * loads there is loaded in the process that serves the scrapes.
 *
 * @module prometheus_exporter_probe
 */

'use strict';

import * as uloop from 'uloop';
import { seconds } from 'prometheus_exporter.deadline';

/**
 * How loading a module went in the probe's child process: whether it
 * loaded, the first line of what loading it threw, whether it was stopped
 * for hanging, and the seconds it took; `unprobed` when no child could be
 * forked, and the module is to load where it is used, as before there was
 * one; `data`, with `report`, what loading it returned there; `stopped`,
 * the signal that asked this process to stop before the module was loaded
 * (see probe()).
 *
 * @typedef {{ ok: boolean, error: ?string, hung: boolean, seconds: float, unprobed: ?boolean, data: ?Object, stopped: ?int }} ProbeOutcome
 */

/**
 * How often this process looks whether the child is still there, while a
 * collector loads in it, or runs (prometheus_exporter.runner): a child that
 * died is noticed within this many milliseconds. Each look is a timer's
 * wakeup, a few microseconds.
 *
 * @type {int}
 */
export const POLL_MS = 100;

function now(env) {
	return seconds(env.clock());
}

/**
 * The seconds a collector module may take to load. Its top level declares
 * what it exports and little else: loading every collector the packages have
 * takes the devenv 46 ms (load:full in the benchmark), about 1.5 ms a module,
 * and a 500-MIPS MIPS router about forty times that. Five seconds is a
 * hundred times what the largest takes there, and still what a router starts
 * uhttpd in, should one never finish.
 *
 * @type {int}
 */
export const LOAD_TIMEOUT = 5;

/**
 * Each of the modules `ids` loaded with import_fn(id) (loader.import_module)
 * in a child process first, as a scrape's collectors run (runner.forked): one
 * that does not load within `seconds` (LOAD_TIMEOUT) is stopped with its
 * process, and a new one loads the rest. { <id>: { ok, error, hung,
 * seconds } }: error, the first line of what loading it threw; hung, whether
 * it was stopped. clock_fn: [ s, ns ], monotonic. With `report`, import_fn
 * returns what to report of the module, data that crosses a pipe in a
 * message of at most PIPE_BUF bytes (the loader's check_module), which its
 * outcome holds as `data`.
 *
 * Only what loads here is then loaded in the process that serves the scrapes:
 * a module whose top level never returns would keep uhttpd from ever serving.
 * Each module is so compiled twice, once here and once there. Both loads run
 * its top level under prometheus_exporter.collection's top_level, which
 * refuses what blocks, ends or writes to the process, or loads code, before
 * it runs (COLLECTOR_IMPURE): here, the time limit stops what that does not,
 * a loop that never ends.
 *
 * While it waits for the child, uloop takes SIGTERM and SIGINT: one ends the
 * wait, and is forgotten by the next uloop.run(), uhttpd's own, where it
 * would have ended the process. uhttpd runs its handler before that, so
 * procd's SIGTERM to an instance still loading its collectors (a reload in
 * an upgrade of several packages, a package's after another's) left it
 * serving, without them, until procd killed it 5 s later. Each module not
 * loaded then has an outcome that says so, `stopped` the signal: the
 * process was asked to stop, and its caller does (app's create).
 *
 * @param {string[]} ids the modules' names.
 * @param {function(string): CollectorModule} import_fn what loads a module.
 * @param {?(int|float)} seconds what loading one may take; LOAD_TIMEOUT when
 *   null.
 * @param {?function(): int[]} clock_fn a monotonic clock, [ s, ns ];
 *   clock(true) when null.
 * @param {?boolean} report whether import_fn's value is reported.
 * @returns {Object<string, ProbeOutcome>} each module's, by name.
 */
export function probe(ids, import_fn, seconds, clock_fn, report) {
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
			let error = null, data = null;

			try {
				data = st.import_fn(id);
			} catch (e) {
				error = substr(split(e.message, '\n')[0], 0, 1024);
			}

			// No longer than PIPE_BUF, as the runner's child_of says.
			pipe.send({ id, error, data: report ? data : null });
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
			finish({ ok: msg.error == null, error: msg.error, hung: false, ...(report ? { data: msg.data } : {}) });
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

	let signal = st.done ? 0 : uloop.run();

	// Ended before the probe was done: the child is stopped with what it was
	// loading, and the rest is not loaded. By a signal, each says so; by
	// anything else, which nothing here does, each is left without an
	// outcome.
	if (!st.done) {
		if (st.task && !st.task.finished())
			st.task.kill();
		if (signal > 0)
			for (let id in [ ...(st.id != null ? [ st.id ] : []), ...left ])
				out[id] = { ok: false, error: `not loaded: this process was asked to stop (signal ${signal})`, hung: false, seconds: 0, stopped: signal };
	}

	timer.cancel();
	uloop.done();
	st.import_fn = null;
	st.task = null;
	st.done = true;

	return out;
};
