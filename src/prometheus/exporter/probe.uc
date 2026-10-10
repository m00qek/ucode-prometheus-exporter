/**
 * The load probe: collector modules loaded in a child process first.
 *
 * @module prometheus_exporter_probe
 */

'use strict';

import * as uloop from 'uloop';
import { seconds } from 'prometheus.exporter.deadline';

/**
 * How loading a module went in the probe's child process.
 *
 * @typedef {{ ok: boolean, error: ?string, hung: boolean, seconds: float, unprobed: ?boolean, data: ?Object, stopped: ?int }} ProbeOutcome
 */

/** How often, in milliseconds, this process looks whether its child is still there. */
export const POLL_MS = 100;

function now(env) {
	return seconds(env.clock());
}

/** The seconds a collector module may take to load. */
export const LOAD_TIMEOUT = 5;

/** The characters of an outcome's base64 in each message of the child, which crosses the pipe whole. */
export const PART = 2048;

/**
 * Each of the modules `ids` loaded in a child process first, stopped past `seconds`.
 *
 * @param {string[]} ids
 * @param {function(string): CollectorModule} import_fn
 * @param {?(int|float)} seconds
 * @param {?function(): int[]} clock_fn
 * @param {?boolean} report
 * @returns {Object<string, ProbeOutcome>}
 */
export function probe(ids, import_fn, seconds, clock_fn, report) {
	let out = {};
	let left = [ ...ids ];
	let env = { clock: clock_fn ?? (() => clock(true)) };
	let st = { import_fn, task: null, gen: 0, id: null, started: null, done: false, lost: 0, parts: [] };
	let timer = null;

	seconds ??= LOAD_TIMEOUT;

	if (!length(ids))
		return out;

	function child(pipe) {
		for (let id = pipe.receive(); type(id) == 'string'; id = pipe.receive()) {
			let error = null, data = null;

			try {
				data = st.import_fn(id);
			} catch (e) {
				error = substr(split(e.message, '\n')[0], 0, 1024);
			}

			let text = b64enc(sprintf('%J', { error, data: report ? data : null }));

			for (let at = 0; at < length(text); at += PART)
				pipe.send({ id, part: substr(text, at, PART) });
			pipe.send({ id, whole: true });
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
		st.parts = [];
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

		if (msg?.id != st.id)
			return;
		if (type(msg.part) == 'string')
			return push(st.parts, msg.part);
		if (!msg.whole)
			return;

		let o = null;

		try {
			o = json(b64dec(join('', st.parts)) ?? '');
		} catch (e) {
			o = null;
		}

		st.parts = [];
		if (type(o) != 'object')
			return finish({ ok: false, error: 'what its process said of it did not cross whole', hung: false });

		finish({ ok: o.error == null, error: o.error, hung: false, ...(report ? { data: o.data } : {}) });
	}

	function spawn() {
		let g = ++st.gen;

		st.task = uloop.task(child, (msg) => on_output(g, msg), () => on_input(g));

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
