'use strict';

// prometheus_exporter.runner for real: collectors run in forked child
// processes, stopped and killed as a scrape stops them.

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as runner from 'prometheus_exporter.runner';
import * as scrape from 'prometheus_exporter.scrape';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as Result from 'prometheus_exporter.result';
import { seconds } from 'prometheus_exporter.deadline';
import * as fs from 'fs';

function collector(name, collect, meta) {
	return loader.validate(loader.id_of(name), { meta: { name, title: 'Test', help: 'Test.', needs: [], ...(meta ?? {}) }, collect }).data;
}

function now() {
	return seconds(clock(true));
}

// A session over nothing: these collectors need nothing.
function env_of(logs) {
	return {
		session: (to) => deps.session({ fs: {}, ubus: { connect: () => null }, uci: { cursor: () => null }, log: to }),
		clock: () => clock(true),
		log: (level, msg) => push(logs, [ level, msg ]),
	};
}

// Runs `collectors` with the forked runner, each stopped `budget` seconds
// after it starts (or at `cutoff`, when given, and sooner): the runs, in the
// order they ran, and what was logged.
function run_forked(collectors, budget, cutoff) {
	let logs = [];
	let runs = [];
	let queue = [ ...collectors ];
	let plan = {
		next: function() {
			let c = shift(queue);

			if (c == null)
				return null;

			let limit = now() + budget;
			let held = cutoff != null && cutoff < limit;

			return { c, cutoff: null, limit: held ? cutoff : limit, at_deadline: held, budget, settings: { budget, max_samples: 1000, options: {} } };
		},
		done: (job, r) => push(runs, r),
	};

	runner.forked(env_of(logs), scrape.run_one, { collectors }).run(plan);

	return { runs, logs };
}

function gauge(name, value) {
	return collector(name, function(d, out) {
		out.gauge(`${name}_value`)(null, value);
		return Result.ok();
	});
}

const LOOP = collector('loop', function() {
	while (true)
		;
});

const QUITTER = collector('quitter', () => exit(3));

function summary(r) {
	return [ r.name, r.result.ok ? 'ok' : r.result.error ];
}

describe('runner.forked', () => {
	it('runs each collector in a child process and hands back its run, its families packed', () => {
		let pids = [];
		let me = collector('me', function(d, out) {
			out.gauge('me_value')(null, 1);
			return Result.ok();
		});
		let r = run_forked([ gauge('a', 1), me ], 5);

		assert.match([ [ 'a', 'ok' ], [ 'me', 'ok' ] ], map(r.runs, summary));
		assert.match([ { name: 'a_value', type: 'gauge', help: null, lines: [ 'a_value 1' ], values: [], packed: true } ], r.runs[0].families);
		assert.match([ 1, true ], [ r.runs[1].samples, Result.is(r.runs[1].result) ]);
		assert.match([], r.logs);
	});

	it('logs what a collector logged in its child, here', () => {
		let failing = collector('failing', () => Result.err('SOURCE_INVALID', 'garbled'));
		let r = run_forked([ failing ], 5);

		assert.match([ [ 'warning', "collector 'failing': SOURCE_INVALID (garbled)" ] ], r.logs);
	});

	it('stops a collector that never returns at its limit, and runs the rest in a new child', () => {
		let t = now();
		let r = run_forked([ gauge('a', 1), LOOP, gauge('c', 3) ], 0.3);
		let took = now() - t;

		assert.match([ [ 'a', 'ok' ], [ 'loop', 'COLLECTOR_CANCELLED' ], [ 'c', 'ok' ] ], map(r.runs, summary));
		assert.match([ true, 0, [] ], [ index(r.runs[1].result.details, 'over its budget of 0 s: stopped') > 0, r.runs[1].samples, r.runs[1].families ]);
		assert.match(true, took < 1.5, `took ${took} s`);
		assert.match([ [ 'warning', `collector 'loop': ${Result.describe(r.runs[1].result)}` ] ], r.logs);
	});

	it('stops it at the deadline as SCRAPE_DEADLINE, which the scrape logs in its line', () => {
		let r = run_forked([ LOOP ], 5, now() + 0.2);

		assert.match([ [ 'loop', 'SCRAPE_DEADLINE' ] ], map(r.runs, summary));
		assert.match({ deadline: true }, r.runs[0].result.data);
		assert.match([], r.logs);
	});

	it('stops one blocked in a system call, which nothing in its process could stop', () => {
		let p = fs.pipe();
		let reader = collector('reader', function() {
			p[0].read(1);
			return Result.ok();
		});
		let r = run_forked([ reader, gauge('b', 2) ], 0.3);

		p[1].close();
		p[0].close();
		assert.match([ [ 'reader', 'COLLECTOR_CANCELLED' ], [ 'b', 'ok' ] ], map(r.runs, summary));
	});

	it('fails a collector whose process ended under it, alone', () => {
		let r = run_forked([ QUITTER, gauge('b', 2) ], 5);

		assert.match([ [ 'quitter', 'COLLECTOR_KILLED' ], [ 'b', 'ok' ] ], map(r.runs, summary));
		assert.match([ [ 'warning', `collector 'quitter': ${Result.describe(r.runs[0].result)}` ] ], r.logs);
	});

	it('leaves no child behind', () => {
		run_forked([ LOOP, QUITTER, gauge('a', 1) ], 0.2);

		let me = split(fs.readfile('/proc/self/stat'), ' ')[0];
		let children = filter(fs.glob('/proc/[0-9]*/stat'), (f) => split(fs.readfile(f) ?? '', ') ')[1] != null &&
			split(split(fs.readfile(f), ') ')[1], ' ')[1] == me && split(split(fs.readfile(f), ') ')[1], ' ')[0] != 'Z');

		assert.match([], children);
	});

	prop('hands back exactly one run per collector the plan picks, in its order, whatever they do',
		gen.array(gen.elements('ok', 'err', 'loop', 'quit', 'none'), { min_len: 1, max_len: 5 }), (kinds) => {
			let made = map(kinds, (k, i) => collector(`k${i}`, {
				ok: () => Result.ok(),
				err: () => Result.err('SOURCE_INVALID'),
				loop: () => { while (true) ; },
				quit: () => exit(1),
				none: () => Result.none('not there'),
			}[k]));
			let r = run_forked(made, 0.15);
			let want = { ok: 'ok', err: 'SOURCE_INVALID', loop: 'COLLECTOR_CANCELLED', quit: 'COLLECTOR_KILLED', none: 'ok' };

			assert.match(map(kinds, (k, i) => [ `k${i}`, want[k] ]), map(r.runs, summary));
		}, { runs: 8 });
});

describe('runner.probe', () => {
	it('loads each module in a child, and stops one that does not load in time', () => {
		let t = now();
		let res = runner.probe([ 'a', 'stuck', 'broken', 'b' ], function(id) {
			if (id == 'stuck')
				while (true)
					;
			if (id == 'broken')
				die('Unable to compile module\nmore');
			return {};
		}, 1);
		let took = now() - t;

		assert.match({ a: true, stuck: false, broken: false, b: true }, { a: res.a.ok, stuck: res.stuck.ok, broken: res.broken.ok, b: res.b.ok });
		assert.match([ true, 'still loading after 1 s: stopped' ], [ res.stuck.hung, res.stuck.error ]);
		assert.match([ false, 'Unable to compile module' ], [ res.broken.hung, res.broken.error ]);
		assert.match(true, took < 2.5, `took ${took} s`);
	});

	it('says a module whose loading ended its process did not load', () => {
		let res = runner.probe([ 'quits', 'b' ], (id) => (id == 'quits') ? exit(1) : {}, 1);

		assert.match([ false, true ], [ res.quits.ok, res.b.ok ]);
	});

	it('loads the real collectors', () => {
		let ids = loader.discover(fs, 'src/prometheus_exporter/collectors');
		let res = runner.probe(ids, loader.import_module);

		assert.match([], filter(ids, (id) => !res[id]?.ok));
	});
});
