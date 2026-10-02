'use strict';

// prometheus_exporter.runner for real: collectors run in forked child
// processes, stopped and killed as a scrape stops them.

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as runner from 'prometheus_exporter.runner';
import * as scrape from 'prometheus_exporter.scrape';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as Result from 'prometheus_exporter.result';
import * as exposition from 'prometheus_exporter.exposition';
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
		mkstemp: fs.mkstemp,
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

			return { c, cutoff: null, limit: held ? cutoff : limit, at_deadline: held, budget, settings: { budget, max_samples: c.meta.max_samples ?? 1000, options: {} } };
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

	// A pipe holds 64 kB: a run that long once crossed it half, and was lost.
	it('hands back a run of a megabyte whole, its labels and help as they were', () => {
		let big = collector('big', function(d, out) {
			let g = out.gauge('big_value', 'Help with "quotes" and a \\ backslash.');

			for (let i = 0; i < 900; i++)
				g({ i, quoted: 'a "b" \\ c' }, i);
			out.counter('big_total', 'Another.')(null, 1);
			d.log('a line logged on the way');
			return Result.ok();
		}, { needs: [ 'log' ] });
		let r = run_forked([ big, gauge('after', 1) ], 5);
		let text = exposition.render(r.runs[0].families);
		let parsed = exposition.parse(text);

		assert.match([ [ 'big', 'ok' ], [ 'after', 'ok' ] ], map(r.runs, summary));
		assert.match([ true, 901, 2 ], [ parsed.ok, r.runs[0].samples, length(parsed.data) ]);
		assert.match('Help with "quotes" and a \\ backslash.', parsed.data[0].help);
		assert.match([ 'i', '899', 'quoted', 'a "b" \\ c' ], [ ...parsed.data[0].samples[899].labels[0], ...parsed.data[0].samples[899].labels[1] ]);
		assert.match([ [ 'warning', "collector 'big': a line logged on the way" ] ], r.logs);
	});

	it('hands back a run far larger than a pipe holds', () => {
		let big = collector('huge', function(d, out) {
			let g = out.gauge('huge_value');

			for (let i = 0; i < 20000; i++)
				g({ i: sprintf('%080d', i) }, i);
			return Result.ok();
		}, { max_samples: 20000 });
		let r = run_forked([ big ], 5);

		assert.match([ 'ok', 20000 ], [ summary(r.runs[0])[1], length(split(r.runs[0].families[0].lines[0], '\n')) ]);
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

describe('textfile, on a real directory', () => {
	it('skips a FIFO that nothing writes to, rather than wait on it', () => {
		let dir = fs.mkdtemp('/tmp/textfile-XXXXXX');
		let logs = [];

		fs.writefile(`${dir}/a.prom`, 'a_value 1\n');
		system(`mkfifo '${dir}/b.prom'`);

		let textfile = loader.import_module('textfile');
		let rec = exposition.recorder();
		let t = now();
		let res = textfile.collect({ fs: { glob: fs.glob, stat: fs.stat, readfile: fs.readfile }, log: (m) => push(logs, m) }, rec, { directory: dir });
		let took = now() - t;

		fs.unlink(`${dir}/a.prom`);
		fs.unlink(`${dir}/b.prom`);
		fs.rmdir(dir);

		assert.match([ true, [ `skipped ${dir}/b.prom: is not a regular file (fifo): not read` ] ], [ res.ok, logs ]);
		assert.match(contains([ 'a_value 1' ]), split(exposition.render(rec.families()), '\n'));
		assert.match(true, took < 1, `took ${took} s`);
	});
});
