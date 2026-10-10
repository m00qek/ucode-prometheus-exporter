'use strict';

// prometheus.exporter.runner for real: collectors run in forked child
// processes, stopped and killed as a scrape stops them.

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as runner from 'prometheus.exporter.runner';
import * as scrape from 'prometheus.exporter.scrape';
import * as loader from 'prometheus.exporter.loader';
import * as deps from 'prometheus.exporter.deps';
import * as Result from 'prometheus.exporter.result';
import * as api from 'prometheus.exporter';
import * as exposition from 'prometheus.exporter.exposition';
import * as ledger from 'prometheus.exporter.ledger';
import { seconds } from 'prometheus.exporter.deadline';
import * as fs from 'fs';
import { with_mods } from 'prometheus.exporter.devkit.collector';

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
		open: fs.open,
	};
}

// A plan of `collectors`, in their order, as the runner takes one: next()
// gives job(c) of the next, in whichever process asks, and done() goes on
// after the collector of the run it is handed, which it pushes to `runs`.
function plan_of(collectors, job, runs) {
	let at = 0;

	return {
		next: () => (at < length(collectors)) ? job(collectors[at++]) : null,
		done: function(j, r) {
			at = max(at, index(collectors, j.c) + 1);
			push(runs, r);
		},
	};
}

// Runs `collectors` with the forked runner, each stopped `budget` seconds
// after it starts (or at `cutoff`, when given, and sooner): the runs, in the
// order they ran, and what was logged.
function run_forked(collectors, budget, cutoff) {
	let logs = [];
	let runs = [];
	let plan = plan_of(collectors, function(c) {
		let limit = now() + budget;
		let held = cutoff != null && cutoff < limit;

		return { c, cutoff: null, limit: held ? cutoff : limit, at_deadline: held, budget, settings: { budget, max_samples: c.meta.max_samples ?? 1000, options: {} } };
	}, runs);

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
	it('runs each collector in a child process and hands back its run, its families\' names and its text', () => {
		let pids = [];
		let me = collector('me', function(d, out) {
			out.gauge('me_value')(null, 1);
			return Result.ok();
		});
		let r = run_forked([ gauge('a', 1), me ], 5);

		assert.match([ [ 'a', 'ok' ], [ 'me', 'ok' ] ], map(r.runs, summary));
		assert.match([ [ 'a_value' ], '# TYPE a_value gauge\na_value 1\n' ], [ r.runs[0].families, r.runs[0].text ]);
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
		let parsed = exposition.parse(r.runs[0].text);

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

		assert.match([ 'ok', 20000 ], [ summary(r.runs[0])[1], length(filter(split(r.runs[0].text, '\n'), (l) => index(l, 'huge_value{') == 0)) ]);
	});

	it('logs at most LOG_LINES lines of a collector\'s run, then how many more it left out', () => {
		let chatty = collector('chatty', function(d) {
			for (let i = 0; i < 1000; i++)
				d.log(`line ${i}`);
			return Result.ok();
		}, { needs: [ 'log' ] });
		let r = run_forked([ chatty, gauge('after', 1) ], 5);

		assert.match([ deps.LOG_LINES + 1, [ 'warning', "collector 'chatty': 990 more lines of its log left out" ] ], [ length(r.logs), r.logs[-1] ]);
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

	// A child that dies before it runs a collector: its session
	// (env.session) ends it, at the calls `dying` names, counted in a file
	// as the children cannot count in this process.
	function dying_env(logs, dying) {
		let count = fs.mkstemp('/tmp/runner-sessions.XXXXXX');
		let env = env_of(logs);

		return {
			...env,
			session: function(to) {
				count.write('x');
				count.flush();
				count.seek(0);
				if (length(count.read('all')) in dying)
					exit(1);
				return env.session(to);
			},
		};
	}

	function run_with(env, collectors, budget, stats) {
		let runs = [];
		let plan = plan_of(collectors,
			(c) => ({ c, cutoff: null, limit: now() + budget, at_deadline: false, budget, settings: { budget, max_samples: 1000, options: {} } }), runs);

		runner.forked(env, scrape.run_one, { collectors, stats }).run(plan);
		return runs;
	}

	it('gives up after two children in a row die before running a collector, and leaves the rest not run, their breakers as they were', () => {
		let logs = [];
		let stats = {};
		let runs = run_with(dying_env(logs, [ 1, 2, 3, 4, 5, 6, 7, 8 ]), [ gauge('a', 1), gauge('b', 2) ], 5, stats);

		assert.match([ [ 'a', 'COLLECTOR_NOT_RUN' ], [ 'b', 'COLLECTOR_NOT_RUN' ] ], map(runs, summary));
		assert.match(2, stats.children, 'two children, not one more');
		assert.match([ 'neutral', 'neutral' ], map(runs, (r) => ledger.outcome_of(r)[0]));
		assert.match([ [ 'warning', 'the processes forked to run the collectors in ended twice before running one; not run: a, b' ] ], logs);
	});

	it('counts the children that die before running one anew once one ran a collector', () => {
		let runs = run_with(dying_env([], [ 1, 3 ]), [ gauge('a', 1), LOOP, gauge('c', 3) ], 0.3, {});

		assert.match([ [ 'a', 'ok' ], [ 'loop', 'COLLECTOR_CANCELLED' ], [ 'c', 'ok' ] ], map(runs, summary));
	});

	// The in-process runner the tests use, and the forked one the service
	// does: a failure without a code once was COLLECTOR_KILLED across the
	// pipe, which quarantines at once, and null here.
	it('gives a failure without an error code the same code forked and inline: COLLECTOR_NO_RESULT, never COLLECTOR_KILLED', () => {
		let codeless = collector('codeless', () => Result.err(null, 'garbled'));
		let unknown = collector('unknown', () => Result.err(api.errors.COLLECTOR_CRASHED));
		let forked = run_forked([ codeless, unknown ], 5).runs;
		let inline = [];

		runner.inline(env_of([]), scrape.run_one).run(plan_of([ codeless, unknown ],
			(c) => ({ c, settings: { budget: 5, max_samples: 10, options: {} } }), inline));

		assert.match([ [ 'codeless', 'COLLECTOR_NO_RESULT' ], [ 'unknown', 'COLLECTOR_NO_RESULT' ] ], map(forked, summary));
		assert.match(map(forked, (r) => Result.describe(r.result)), map(inline, (r) => Result.describe(r.result)));
		assert.match('COLLECTOR_NO_RESULT (failed without an error code: garbled)', Result.describe(forked[0].result));
	});

	it('unpacks a run packed with a failure without a code as COLLECTOR_NO_RESULT', () => {
		let packed = runner.pack({ name: 'x', id: 'x', samples: 0, duration: 0, families: [], result: { ok: false }, text: '' }, []);

		assert.match('COLLECTOR_NO_RESULT', runner.unpack(packed).run.result.error);
	});

	// A child stopped while it wrote a run leaves part of one: it is not a run.
	prop('unpacks the runs packed one after another, and none of what is cut short of one',
		gen.tuple(gen.array(gen.tuple(gen.string({ min_len: 0, max_len: 40 }), gen.elements('ok', 'err', 'none')), { min_len: 1, max_len: 4 }),
			gen.int(0, 10000)), (t) => {
			let runs = map(t[0], (x, i) => ({
				name: `c${i}`, id: `c${i}`, samples: i, duration: 0.5, budget: 5, families: [ `f${i}`, 'g' ], text: x[0],
				result: { ok: Result.ok(), err: Result.err('SOURCE_INVALID', 'why'), none: Result.none('absent') }[x[1]],
			}));
			let text = join('', map(runs, (r, i) => runner.pack(r, [ [ 'warning', `line ${i}` ] ])));
			let cut = t[1] % (length(text) + 1);
			let got = [];

			for (let u = runner.unpack(text, 0); u != null; u = runner.unpack(text, u.end))
				push(got, u);

			assert.match(map(runs, (r) => [ r.name, r.text, r.families, Result.describe(r.result), Result.is_none(r.result) ]),
				map(got, (u) => [ u.run.name, u.run.text, u.run.families, Result.describe(u.run.result), Result.is_none(u.run.result) ]));
			assert.match(map(runs, (r, i) => [ [ 'warning', `line ${i}` ] ]), map(got, (u) => u.logs));

			let short = substr(text, 0, cut);
			let left = [];

			for (let u = runner.unpack(short, 0); u != null; u = runner.unpack(short, u.end))
				push(left, u.run.name);

			assert.match(map(filter(got, (u) => u.end <= cut), (u) => u.run.name), left, `cut at ${cut} of ${length(text)}`);
		});

	// Each fallback says why: a full tmpfs once logged that it could not fork.
	it('runs the collectors in this process when the file their runs cross by cannot be made, and says that, not that it cannot fork', () => {
		let logs = [];
		let runs = [];
		let plan = plan_of([ gauge('a', 1), gauge('b', 2) ],
			(c) => ({ c, cutoff: null, limit: null, at_deadline: false, budget: 5, settings: { budget: 5, max_samples: 10, options: {} } }), runs);

		runner.forked({ ...env_of(logs), mkstemp: () => null }, scrape.run_one, { tmp: '/nowhere' }).run(plan);

		assert.match([ [ 'a', 'ok' ], [ 'b', 'ok' ] ], map(runs, summary));
		assert.match([ [ 'warning', "cannot make the file the collectors' runs cross by, in /nowhere; running the collectors in the scrape's own process" ] ], logs);
	});

	// A program a collector started, killed with its child, would run on: three
	// scrapes once left three sleeps. system() is refused by the loader; a
	// native module's process, or one started any other way, is not.
	it('kills what a collector it stops started, with its child', () => {
		let starter = collector('starter', function() {
			// Its descriptors closed, so that one left running holds no
			// pipe of the scrape's open: it shows, rather than hangs it.
			system('for fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do eval "exec $fd>&-"; done; exec sleep 3083 </dev/null >/dev/null 2>&1');
			return Result.ok();
		});
		let runs = [];
		let plan = plan_of([ starter ],
			(c) => ({ c, cutoff: null, limit: now() + 0.5, at_deadline: false, budget: 0, settings: { budget: 0, max_samples: 10, options: {} } }), runs);

		runner.forked({ ...env_of([]), kill: (pid) => deps.kill_tree(fs.popen, pid) }, scrape.run_one, { collectors: [ starter ] }).run(plan);

		let sleeping = filter(fs.glob('/proc/[0-9]*/cmdline'), (f) => fs.readfile(f) == 'sleep\u00003083\u0000');

		assert.match([ [ [ 'starter', 'COLLECTOR_CANCELLED' ] ], [] ], [ map(runs, summary), sleeping ]);
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

// A child that went wrong: its plan, which runs in it, gives limits the
// deadline does not bound, or runs on past it. The deadline is this process's
// (opts.deadline), which the child's plan does not know.
describe('runner.forked, a child that went wrong, held to the deadline', () => {
	const BACKSTOP = 'the process running the collectors ran past the scrape\'s deadline, past the limits it gave: stopped there, the rest left out';

	// This process's pid, or a child's, asked where it runs.
	function pid() {
		return split(fs.readfile('/proc/self/stat'), ' ')[0];
	}

	// A collector that takes `s` seconds, and writes a sample.
	function slow(name, s) {
		return collector(name, function(d, out) {
			let end = now() + s;

			while (now() < end)
				;
			out.gauge(`${name}_value`)(null, 1);
			return Result.ok();
		});
	}

	// The live children of this process, as 'leaves no child behind' finds
	// them.
	function children() {
		let me = pid();

		return filter(fs.glob('/proc/[0-9]*/stat'), function(f) {
			let rest = split(fs.readfile(f) ?? '', ') ')[1];

			return rest != null && split(rest, ' ')[1] == me && split(rest, ' ')[0] != 'Z';
		});
	}

	// Runs `collectors` with the forked runner and the deadline `after`
	// seconds from now, each job job(c), in the child: the runs, what was
	// logged, the children forked, and the seconds the run took past the
	// deadline.
	function run_late(collectors, after, job, plan) {
		let logs = [];
		let runs = [];
		let stats = {};
		let deadline = now() + after;

		plan ??= plan_of(collectors, job, runs);
		// readfile: a child that runs to its end reads its memory for
		// stats, and one that cannot ends before it says so.
		runner.forked({ ...env_of(logs), readfile: fs.readfile, kill: (p) => deps.kill_tree(fs.popen, p) }, scrape.run_one,
			{ collectors, stats, deadline }).run(plan);

		return { runs, logs, children: stats.children, past: now() - deadline };
	}

	function job_of(limit) {
		return (c) => ({ c, cutoff: null, limit: limit(), at_deadline: false, budget: 5, settings: { budget: 5, max_samples: 10, options: {} } });
	}

	// Stopped at the deadline, give or take a turn of the timer.
	function on_time(r) {
		assert.match(true, r.past > -0.05 && r.past < runner.GRACE + 0.25, `${r.past} s past the deadline`);
	}

	function left_out(r) {
		return [ r.name, r.result.error, r.skipped ];
	}

	it('stops a collector it gave no limit at the deadline, forks no other child, and leaves the rest out there', () => {
		let r = run_late([ gauge('a', 1), LOOP, gauge('c', 3), gauge('d', 4) ], 0.3, job_of(() => null));

		on_time(r);
		assert.match([ [ 'a', 'ok' ], [ 'loop', 'SCRAPE_DEADLINE' ], [ 'c', 'SCRAPE_DEADLINE' ], [ 'd', 'SCRAPE_DEADLINE' ] ], map(r.runs, summary));
		assert.match(true, index(r.runs[1].result.details, 'still running at the scrape\'s deadline') == 0, r.runs[1].result.details);
		assert.match([ [ 'c', 'SCRAPE_DEADLINE', 'deadline' ], [ 'd', 'SCRAPE_DEADLINE', 'deadline' ] ], map(slice(r.runs, 2), left_out));
		assert.match([ 1, [ [ 'warning', BACKSTOP ] ], [] ], [ r.children, r.logs, children() ]);
	});

	it('stops one at the deadline whose limit it gave past it', () => {
		let r = run_late([ LOOP, gauge('b', 2) ], 0.3, job_of(() => now() + 60));

		on_time(r);
		assert.match([ [ 'loop', 'SCRAPE_DEADLINE' ], [ 'b', 'SCRAPE_DEADLINE', 'deadline' ] ], [ summary(r.runs[0]), left_out(r.runs[1]) ]);
		assert.match([ 1, [ [ 'warning', BACKSTOP ] ] ], [ r.children, r.logs ]);
	});

	it('honours a limit it gave before the deadline, as it would any', () => {
		let r = run_late([ LOOP, gauge('b', 2) ], 2, job_of(() => now() + 0.2));

		assert.match([ [ 'loop', 'COLLECTOR_CANCELLED' ], [ 'b', 'ok' ] ], map(r.runs, summary));
		assert.match([ 2, [ [ 'warning', `collector 'loop': ${Result.describe(r.runs[0].result)}` ] ] ], [ r.children, r.logs ]);
	});

	it('stops a child that goes on starting collectors past the deadline, and keeps the runs it ended', () => {
		let made = map([ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ], (i) => slow(`s${i}`, 0.06));
		let r = run_late(made, 0.3, job_of(() => now() + 5));
		let ok = filter(r.runs, (x) => x.result.ok);
		let rest = slice(r.runs, length(ok));

		on_time(r);
		assert.match(map(made, (c) => c.meta.name), map(r.runs, (x) => x.name), 'one run each, in their order');
		assert.match(true, length(ok) >= 3 && length(rest) >= 4, `${length(ok)} ran`);
		assert.match(map(rest, () => 'SCRAPE_DEADLINE'), map(rest, (x) => x.result.error));
		assert.match([ 'deadline', 'deadline' ], [ rest[-2].skipped, rest[-1].skipped ]);
		assert.match([ 1, [ [ 'warning', BACKSTOP ] ] ], [ r.children, r.logs ]);
	});

	// The run before a collector it starts is written with its start: so
	// a child that hangs after a collector holds this process to that one.
	it('stops a child that hangs between collectors, with none started, a turn of the timer past the deadline', () => {
		let me = pid();
		let runs = [];
		let collectors = [ gauge('a', 1), gauge('b', 2), gauge('c', 3) ];
		let at = 0;
		// Its next() hangs before the first collector, in the child alone.
		let plan = {
			next: function() {
				if (at == 0 && pid() != me)
					while (true)
						;

				return (at < length(collectors)) ? job_of(() => now() + 5)(collectors[at++]) : null;
			},
			done: function(j, r) {
				at = max(at, index(collectors, j.c) + 1);
				push(runs, r);
			},
		};
		let r = run_late(collectors, 0.3, null, plan);

		on_time(r);
		assert.match(true, r.past >= runner.GRACE - 0.02, `${r.past} s past the deadline`);
		assert.match([ [ 'a', 'SCRAPE_DEADLINE', 'deadline' ], [ 'b', 'SCRAPE_DEADLINE', 'deadline' ], [ 'c', 'SCRAPE_DEADLINE', 'deadline' ] ],
			map(runs, left_out));
		assert.match([ 1, [ [ 'warning', BACKSTOP ] ], [] ], [ r.children, r.logs, children() ]);
	});

	it('never stops a child that keeps to its limits, which ends before the deadline or stops its collector there', () => {
		let quick = run_late([ gauge('a', 1), gauge('b', 2) ], 0.5, job_of(() => now() + 5));
		let t = now();
		let held = run_late([ gauge('a', 1), LOOP ], 0.3, job_of(() => t + 0.3));

		assert.match([ [ [ 'a', 'ok' ], [ 'b', 'ok' ] ], 1, [] ], [ map(quick.runs, summary), quick.children, quick.logs ]);
		assert.match(true, quick.past < 0, 'it did not wait for the deadline');
		assert.match([ [ [ 'a', 'ok' ], [ 'loop', 'COLLECTOR_CANCELLED' ] ], [] ],
			[ map(held.runs, summary), filter(held.logs, (l) => l[1] == BACKSTOP) ]);
	});
});

describe('scrape.collect, forked', () => {
	// The limit a collector is stopped at is its budget's end (5 s by
	// default), or the deadline when that comes first.
	it('stops a collector at the deadline, when it comes before its budget\'s end, as SCRAPE_DEADLINE', () => {
		let runs;
		let t = now();

		with_mods({}, (mods) => {
			let env = { ...env_of([]), session: (to) => deps.session({ ...mods, log: to }), fork: true };

			runs = scrape.collect(env, mods.uci.cursor(), ledger.empty(), [ LOOP ], { deadline: now() + 0.4 });
		});

		let took = now() - t;

		assert.match('SCRAPE_DEADLINE', runs.loop.result.error);
		assert.match(true, took < 2, `took ${took} s`);
	});

	// The child's limits are the deadline at the latest, and it leaves the
	// rest out there itself: the runner's own hold on it is never what stops it.
	it('stops the child of a scrape that keeps to its limits as it says, never at the deadline over it', () => {
		let logs = [];
		let stats = {};
		let runs;

		with_mods({}, (mods) => {
			let env = { ...env_of(logs), readfile: fs.readfile, session: (to) => deps.session({ ...mods, log: to }), fork: true, stats };

			runs = scrape.collect(env, mods.uci.cursor(), ledger.empty(), [ gauge('a', 1), LOOP, gauge('c', 3) ], { deadline: now() + 0.4 });
		});

		assert.match([ 'ok', 'SCRAPE_DEADLINE', 'SCRAPE_DEADLINE' ], [ runs.a.result.ok ? 'ok' : runs.a.result.error, runs.loop.result.error, runs.c.result.error ]);
		assert.match([ 'deadline', 2 ], [ runs.c.skipped, stats.children ]);
		assert.match([], filter(logs, (l) => index(l[1], 'past the limits it gave') >= 0));
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
