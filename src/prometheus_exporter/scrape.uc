/**
 * One scrape: pick the collectors the query asks for, run each with its deps and
 * options, time it, and write every family once, followed by node_exporter's
 * node_scrape_collector_duration_seconds and node_scrape_collector_success,
 * node_scrape_collector_observing, and the exporter's own
 * ucode_prometheus_exporter_collector_quarantined and
 * ucode_prometheus_exporter_build_info.
 *
 * A collector with nothing to observe (Result.none: its hardware, kernel
 * feature or service is not there) succeeds, writes no samples and is not
 * logged: it is what the device is, every scrape. Its
 * node_scrape_collector_observing is 0, so a dashboard tells it from one that
 * observes and finds nothing to count; every other collector's is 1.
 *
 * The handler's scrapes keep a ledger in the instance's state
 * (prometheus_exporter.ledger): how long each collector took, how many
 * samples it wrote, and its circuit breaker (prometheus_exporter.breaker).
 * They run the collectors fastest first by it, so that a deadline leaves out
 * the few slow ones rather than the many fast ones; the reply has them in the
 * order the query selects, whatever order they ran in. A collector whose
 * breaker is open is not run, even when the query names it: it fails with
 * COLLECTOR_QUARANTINED, and its ucode_prometheus_exporter_collector_quarantined
 * is 1. The scrape logs a breaker that trips or closes, not each scrape that
 * leaves a collector out.
 *
 * A scrape may have a deadline (prometheus_exporter.deadline): it then starts
 * no collector the ledger does not expect done in time to write the reply,
 * and none of their programs runs past that. A collector left out so fails
 * with SCRAPE_DEADLINE, as one whose program was killed at the deadline does,
 * and the scrape logs them once, all together, not a line each.
 *
 * Each collector runs as prometheus_exporter.runner runs it: with env.fork,
 * in a child process of the scrape's, stopped at its limit (its budget's end,
 * or the deadline) with the process, and a collector whose process dies under
 * it fails alone; without, in this process, as the tests run it. It writes at
 * most its max_samples, and nothing Prometheus would refuse the whole reply
 * for (prometheus_exporter.exposition's recorder), and a family belongs to
 * the first collector of the reply that writes it: another that writes it
 * fails with FAMILY_CONFLICT (prometheus_exporter.ownership).
 * A collector that breaks one of these rules, or is stopped, fails, and none
 * of its samples are served.
 *
 * env: { session(log) -> a deps session, its collectors' lines logged with
 *        log when given, clock() -> [ s, ns ] monotonic,
 *        log(level, msg): a collector that fails at warning, as the scrape
 *        answers without it; a main section the exporter cannot read at err,
 *        version: the exporter's version (prometheus_exporter.version),
 *        fork: whether to run the collectors in child processes,
 *        tmp: the directory of the file their runs cross by (runner.forked),
 *        stats: an object the runner fills in, for the benchmark }
 *
 * @module prometheus_exporter_scrape
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as exposition from 'prometheus_exporter.exposition';
import * as config from 'prometheus_exporter.config';
import * as query from 'prometheus_exporter.query';
import { seconds as now_of, budget as deadline_budget } from 'prometheus_exporter.deadline';
import * as ledger from 'prometheus_exporter.ledger';
import * as runner from 'prometheus_exporter.runner';
import * as loader from 'prometheus_exporter.loader';
import { pid_of } from 'prometheus_exporter.state';
import { own } from 'prometheus_exporter.ownership';
import { bury, log_breakers } from 'prometheus_exporter.progress';

/**
 * The env a scrape runs collectors in, as the module's top comment says
 * (app.scrape_env makes it): mkstemp and readfile are fs's, which the forked
 * runner takes; kill(pid) kills a collector's child process a scrape left
 * behind (prometheus_exporter.progress).
 *
 * @typedef {{
 *   session: (log: ?Log) => Session,
 *   clock: () => int[],
 *   log: Log,
 *   version: string,
 *   fork: boolean,
 *   tmp: ?string,
 *   stats: ?Object,
 *   mkstemp: ?function(string): ?FsFile,
 *   readfile: ?function(string): ?string,
 *   kill: ?function(int): void
 * }} ScrapeEnv
 */

/**
 * A collector's run, as run_one, not_run and the runner give it: its name
 * and module name, its Result, its families (a recorder's, or once packed
 * their names and types alone), the samples it wrote, the seconds it took
 * and its budget; `skipped`, why it did not run ('quarantine', 'deadline'),
 * and `text`, its families as the reply holds them, once packed.
 *
 * @typedef {{
 *   name: string,
 *   id: string,
 *   result: Result,
 *   families: (RecordedFamily|{ name: string, type: string })[],
 *   samples: int,
 *   duration: float,
 *   budget: ?int,
 *   skipped: ?string,
 *   text: ?string
 * }} Run
 */

/**
 * A scrape's reply, as scrape() gives it: its HTTP status line, its content
 * type and its body.
 *
 * @typedef {{ status: string, content_type: string, body: string }} ScrapeReply
 */

/**
 * scrape()'s options: when the collectors must be done by (monotonic
 * seconds), the seconds that left them, and the instance's state.
 *
 * @typedef {{ deadline: ?float, budget: ?float, state: ?State }} ScrapeOptions
 */

/**
 * collect()'s options, as its comment says.
 *
 * @typedef {{
 *   deadline: ?float,
 *   quarantine: ?boolean,
 *   collectors: ?Collector[],
 *   pid: ?int,
 *   kept: ?boolean,
 *   progress: ?ProgressFile,
 *   omit: ?boolean,
 *   main: ?Result<MainSettings>
 * }} CollectOptions
 */

/**
 * The content type of a scrape's reply: the text exposition format, 0.0.4.
 *
 * @type {string}
 */
export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

/**
 * The family that says the exporter's version.
 *
 * @type {string}
 */
export const BUILD_INFO = 'ucode_prometheus_exporter_build_info';

/**
 * The family that says whether a collector is quarantined.
 *
 * @type {string}
 */
export const QUARANTINED = 'ucode_prometheus_exporter_collector_quarantined';

function seconds(t1, t2) {
	return (t2[0] - t1[0]) + (t2[1] - t1[1]) / 1000000000.0;
}

/**
 * The collectors a query string selects, in the order it names them (all the
 * enabled ones when it names none), less the excluded. Naming an unknown or a
 * disabled collector is an error; `disabled` holds the module names of those
 * switched off in the config.
 *
 * @param {Collector[]} collectors the installed collectors.
 * @param {?string} query_string the scrape's query string.
 * @param {?string[]} disabled the module names of the disabled ones.
 * @returns {Result<Collector[]>} the collectors selected, or
 *   COLLECTOR_INVALID.
 */
export function select(collectors, query_string, disabled) {
	let q = query.parse(query_string);
	let by_name = {};

	for (let c in collectors) {
		by_name[c.meta.name] = c;
		by_name[c.id] = c;
	}

	disabled ??= [];

	for (let name in [ ...q.collect, ...q.exclude ])
		if (!by_name[name])
			return Result.err(errors.COLLECTOR_INVALID, `unknown collector '${name}'`);

	for (let name in q.collect)
		if (by_name[name].id in disabled)
			return Result.err(errors.COLLECTOR_INVALID, `collector '${name}' is disabled`);

	let excluded = map(q.exclude, (n) => by_name[n].id);
	let chosen = length(q.collect) ? map(q.collect, (n) => by_name[n]) : filter(collectors, (c) => !(c.id in disabled));
	let seen = {};

	return Result.ok(filter(chosen, function(c) {
		if (seen[c.id] || c.id in excluded)
			return false;
		return seen[c.id] = true;
	}));
};

// What a collector that wrote more than its `max` samples fails with: how far
// it got, and in which family.
function over_limit(over, max) {
	return Result.err(errors.SAMPLE_LIMIT,
		sprintf('more than its max_samples of %d: stopped at %d samples, in %s', max, over.samples, over.family));
}

// What a collector that wrote more than the `left` samples of the reply's
// max_scrape_samples fails with: neither a failure nor a success of its own,
// to its breaker (ledger.outcome_of).
function over_reply(over, left) {
	return Result.err(errors.SAMPLE_LIMIT,
		sprintf('more than the %d samples left of the reply\'s max_scrape_samples: stopped at %d samples, in %s', left, over.samples, over.family),
		{ scrape: true });
}

// What a collector that wrote what Prometheus refuses fails with: what, and
// where (the recorder's invalid()).
function refused(bad) {
	let where = (bad.family != null) ? `in ${bad.family}` : 'in out.labels()';

	if (bad.label != null)
		where += `, label '${bad.label}'`;

	return Result.err(errors.EXPOSITION_INVALID, `${where}: ${bad.why}`);
}

/**
 * Runs one collector: { name, id, result, families, samples, duration,
 * budget }, budget the seconds it may take (config.settings). What it
 * recorded is kept even when it fails, as upstream exporters do; nothing is
 * when it has nothing to observe, nor when it wrote more than its
 * max_samples, which it fails with SAMPLE_LIMIT, nor when it wrote what
 * Prometheus would refuse the whole scrape for (the recorder's invalid()),
 * which it fails with EXPOSITION_INVALID. job (prometheus_exporter.
 * runner's), when given: its programs never run past job.cutoff (monotonic
 * seconds), its ubus calls past job.limit; job.settings are its settings,
 * read already; job.view is the exporter collector's; it writes at most the
 * job.left samples left of the reply's max_scrape_samples, past which it fails
 * with SAMPLE_LIMIT too.
 *
 * @param {ScrapeEnv} env the scrape's env.
 * @param {Session} session the scrape's session.
 * @param {Collector} collector the collector.
 * @param {?Job} job its job, or null.
 * @returns {Run} the run.
 */
export function run_one(env, session, collector, job) {
	let t1 = env.clock();
	let res = job?.settings ? Result.ok(job.settings) : config.settings(session.uci(), collector.id, collector.meta);
	let budget = res.ok ? res.data.budget : null;
	let max = res.ok ? res.data.max_samples : null;
	let left = job?.left;
	let reply_cap = (left != null && (max == null || left < max));
	let rec = exposition.recorder(reply_cap ? left : max);

	if (res.ok) {
		let settings = res.data;

		res = session.for(collector.meta, settings, job?.cutoff, job?.view, job?.limit);
		if (res.ok) {
			try {
				let r = collector.collect(res.data, rec, settings.options);
				res = Result.is(r) ? r : Result.err(errors.COLLECTOR_NO_RESULT, `returned ${type(r) ?? 'null'}`);
			} catch (e) {
				res = Result.err(errors.COLLECTOR_CRASHED, split(e.message, '\n')[0]);
			}
		}
	}

	let duration = seconds(t1, env.clock());
	let over = rec.over();
	let bad = rec.invalid();

	// However it ended: it may have caught what stopped it.
	if (over)
		res = reply_cap ? over_reply(over, left) : over_limit(over, max);
	else if (bad)
		res = refused(bad);

	// One cut at the deadline is in the scrape's line of them.
	if (!res.ok && res.error != errors.SCRAPE_DEADLINE)
		env.log('warning', `collector '${collector.meta.name}': ${Result.describe(res)}`);
	for (let name in rec.conflicts())
		env.log('warning', `collector '${collector.meta.name}': '${name}' declared with two types; later samples dropped`);

	let families = (Result.is_none(res) || over || bad) ? [] : rec.families();
	let samples = 0;

	for (let f in families)
		samples += length(f.lines);

	return { name: collector.meta.name, id: collector.id, result: res, families, samples, duration, budget };
};

/**
 * A collector left out, without running: { name, id, result, families: [],
 * samples: 0, duration: 0, skipped }.
 *
 * @param {Collector} collector the collector.
 * @param {Result} res what it fails with.
 * @param {string} why 'quarantine', 'deadline', or 'samples': the reply has
 *   its max_scrape_samples already.
 * @returns {Run} the run.
 */
export function not_run(collector, res, why) {
	return { name: collector.meta.name, id: collector.id, result: res, families: [], samples: 0, duration: 0, skipped: why };
};

// Whether a run was cut by the deadline: left out, its program killed there,
// or stopped there.
function at_deadline(r) {
	return r.result.error == errors.SCRAPE_DEADLINE;
}

/**
 * The line the scrape logs of the collectors the deadline left out or cut, or
 * null for none.
 *
 * @param {Run[]} runs the scrape's runs.
 * @param {float} budget the seconds the collectors had.
 * @returns {?string} the line.
 */
export function deadline_line(runs, budget) {
	let names = map(filter(runs, at_deadline), (r) => r.name);

	if (!length(names))
		return null;

	return sprintf('scrape deadline: %d collector%s not served in its %.1f s: %s', length(names),
		length(names) == 1 ? '' : 's', budget, join(', ', names));
};

function reply(status, body) {
	return { status, content_type: CONTENT_TYPE, body };
}

// Whether the collector is to be left out at the deadline, on `l`'s word: the
// time left before `cutoff`, when the reply must start being written, is not
// enough for what it is expected to take, or there is none. Its result then,
// or null to run it.
function too_late(l, c, now, cutoff) {
	let need = ledger.estimate(l, c.id);

	if (now >= cutoff)
		return Result.err(errors.SCRAPE_DEADLINE, 'not run: the scrape\'s time was spent');
	if (need != null && now + need >= cutoff)
		return Result.err(errors.SCRAPE_DEADLINE, sprintf('not run: it takes %.2f s, and %.2f s were left', need, cutoff - now));

	return null;
}

// Where a collector the ledger has not timed runs among the others it has
// not (ledger.order), as on the first scrape after a restart: the exporter's
// own (loader.OWN) first, then those of other packages, which may be a loop
// under a budget longer than the scrape; and of each, one that declares itself
// heavy (meta.cost) after the rest.
function untimed_rank(c) {
	return 1 + ((c.id in loader.OWN) ? 0 : 2) + ((c.meta.cost == 'heavy') ? 1 : 0);
}

// The runner of `chosen` for env (prometheus_exporter.runner): forked with
// env.fork, else inline. `omit`: omit_zero_values.
function runner_of(env, chosen, omit) {
	return env.fork
		? runner.forked(env, run_one, { collectors: chosen, omit, stats: env.stats, tmp: env.tmp })
		: runner.inline(env, run_one, { omit });
}

/**
 * Runs the `chosen` collectors, fastest first by the ledger `l`: each one's
 * run, by id. With `quarantine`, one whose breaker is open does not run. The
 * collectors write at most the main section's max_scrape_samples in all: one
 * whose samples would go past it fails with SAMPLE_LIMIT, and one that would
 * start once they are written is not run. With
 * a deadline, a collector runs only if the ledger expects it done in time to
 * write the reply, its own samples included; its programs never run past that,
 * and it is stopped there. Without one, or before it, it is stopped at its
 * budget's end.
 *
 * A collector that needs `exporter` runs after every other, and sees the
 * scrape so far: the ledger's counters with this scrape's runs, and their
 * samples (deps.exporter_channel). opts: { deadline, quarantine,
 * collectors: the installed ones, pid: the serving process's, null for this
 * one, kept: whether the ledger is the instance's, progress: the scrape's
 * (prometheus_exporter.state), omit: omit_zero_values, main: the main
 * section, config.main's, read here when not given }. The counters name
 * collectors by their names.
 *
 * @param {ScrapeEnv} env the scrape's env.
 * @param {UciCursor} uci the scrape's cursor.
 * @param {Ledger} l the ledger.
 * @param {Collector[]} chosen the collectors to run.
 * @param {?CollectOptions} opts the options.
 * @returns {Object<string, Run>} each collector's run, by id.
 */
export function collect(env, uci, l, chosen, opts) {
	let by_id = {};
	let collected = 0;
	let m = ledger.number(l);
	let installed = opts?.collectors ?? chosen;
	let ids = map(installed, (c) => c.id);
	let deadline = opts?.deadline;
	let queue = ledger.order(l, chosen, (c) => 'exporter' in c.meta.needs, untimed_rank);
	let next = 0;
	// Read once: every collector's settings default to it.
	let main = opts?.main ?? config.main(uci);
	let reply_max = main.ok ? main.data.max_scrape_samples : config.MAX_SCRAPE_SAMPLES;

	function view() {
		let counters = null;

		if (opts?.kept) {
			let n = ledger.counters(ledger.record(l, values(by_id), null, ids));
			let named = {};

			for (let c in installed)
				if (n.collectors[c.id] != null)
					named[c.meta.name] = n.collectors[c.id];

			counters = { ...n, collectors: named };
		}

		let samples = {};

		for (let id, r in by_id)
			samples[r.name] = r.samples;

		return { pid: opts?.pid, counters, samples };
	}

	let plan = {
		next: function(pid) {
			while (next < length(queue)) {
				let c = queue[next++];

				if (opts?.quarantine && ledger.phase(l, c.id, m) == 'open') {
					by_id[c.id] = not_run(c, ledger.quarantined(l, c.id, m), 'quarantine');
					continue;
				}

				let now = now_of(env.clock());
				let cutoff = null;

				if (deadline != null) {
					cutoff = deadline - ledger.writing(l, collected + ledger.samples(l, c.id));

					let late = too_late(l, c, now, cutoff);

					if (late) {
						by_id[c.id] = not_run(c, late, 'deadline');
						continue;
					}
				}

				let left = reply_max - collected;

				if (left <= 0) {
					let full = Result.err(errors.SAMPLE_LIMIT,
						sprintf('not run: the reply has its max_scrape_samples of %d', reply_max), { scrape: true });

					env.log('warning', `collector '${c.meta.name}': ${Result.describe(full)}`);
					by_id[c.id] = not_run(c, full, 'samples');
					continue;
				}

				let s = config.settings(uci, c.id, c.meta, main);
				let budget = s.ok ? s.data.budget : null;
				let limit = (budget != null) ? now + budget : null;
				let held = false;

				if (cutoff != null && (limit == null || cutoff < limit)) {
					limit = cutoff;
					held = true;
				}

				opts?.progress?.start(c.id, pid);

				return {
					c, cutoff, limit, at_deadline: held, budget, left,
					settings: s.ok ? s.data : null,
					view: ('exporter' in c.meta.needs) ? view() : null,
				};
			}

			return null;
		},
		done: function(job, r) {
			collected += r.samples;
			by_id[job.c.id] = r;
		},
	};

	runner_of(env, chosen, opts?.omit).run(plan);

	let by_c = {};

	for (let c in chosen)
		by_c[c.id] = c;

	own(env, map(filter(chosen, (c) => by_id[c.id] != null), (c) => by_id[c.id]), by_c);

	return by_id;
};

/**
 * A guarded run of `chosen` outside the service's scrapes: check, the ubus
 * object's status, the command line's collector check. Each collector runs as
 * the service's scrapes run it (env.fork: in a child process, stopped at its
 * limit), with the deadline of a scrape whose scraper says no timeout (the
 * main section's scrape_timeout), ordered by the service's ledger `l` (null
 * for none), quarantined or not: it is there to see what each does now.
 * `installed`: every collector, for the exporter's. Its runs, in the order
 * of `chosen`; one the deadline left out has SCRAPE_DEADLINE.
 *
 * @param {ScrapeEnv} env the env.
 * @param {UciCursor} uci the cursor.
 * @param {?Ledger} l the service's ledger, or null.
 * @param {Collector[]} chosen the collectors to run.
 * @param {?Collector[]} installed every collector; `chosen` when null.
 * @returns {Run[]} the runs.
 */
export function trial(env, uci, l, chosen, installed) {
	let main = config.main(uci);
	let timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let by_id = collect(env, uci, l ?? ledger.empty(), chosen, {
		deadline: now_of(env.clock()) + deadline_budget(timeout), collectors: installed ?? chosen, main,
	});

	return map(chosen, (c) => by_id[c.id]);
};

/**
 * { status, content_type, body } for a scrape with this query string. opts:
 * { deadline: when the collectors must be done by (monotonic seconds),
 *   budget: the seconds that left them, for the log,
 *   state: the instance's state (prometheus_exporter.state), whose ledger
 *          orders the collectors, says which ones the deadline has time
 *          for and which ones their breakers keep out, and records this
 *          scrape }.
 * Whatever order they ran in, the reply has them in the order selected.
 *
 * @param {ScrapeEnv} env the scrape's env.
 * @param {Collector[]} collectors the installed collectors.
 * @param {?string} query_string the request's query string.
 * @param {?ScrapeOptions} opts the options.
 * @returns {ScrapeReply} the reply.
 */
export function scrape(env, collectors, query_string, opts) {
	let session = env.session();
	let uci = session.uci();
	let disabled = map(filter(collectors, (c) => !config.enabled(uci, c.id)), (c) => c.id);
	let sel = select(collectors, query_string, disabled);

	if (!sel.ok) {
		session.close();
		return reply('400 Bad Request', Result.describe(sel) + '\n');
	}

	let main = config.main(uci);
	let main_read = main;

	if (!main.ok) {
		env.log('err', `main: ${Result.describe(main)}`);
		main = Result.ok(config.defaults(config.MAIN_OPTIONS));
	}

	let st = opts?.state;
	let ids = map(collectors, (c) => c.id);

	if (st?.dead)
		bury(env, st, collectors);

	let l = ledger.parse(st?.read(ledger.NAME));
	let progress = st?.progress ? st.progress() : null;
	let by_id = collect(env, uci, l, sel.data, {
		deadline: opts?.deadline, quarantine: true, collectors, pid: st ? pid_of(st.id) : null, kept: st != null,
		progress, omit: main.data.omit_zero_values, main: main_read,
	});
	let runs = map(sel.data, (c) => by_id[c.id]);

	progress?.collected();
	session.close();

	let late = deadline_line(runs, opts?.budget ?? 0);
	if (late)
		env.log('warning', late);

	let t1 = env.clock();
	let scrape_meta = exposition.recorder();
	let duration = scrape_meta.gauge('node_scrape_collector_duration_seconds',
		'node_exporter: Duration of a collector scrape.');
	let success = scrape_meta.gauge('node_scrape_collector_success',
		'node_exporter: Whether a collector succeeded.');

	// Each collector's label, written once for its four samples.
	let labels = map(runs, (r) => scrape_meta.labels({ collector: r.name }));

	for (let i, r in runs)
		duration(labels[i], r.duration);
	for (let i, r in runs)
		success(labels[i], r.result.ok);

	let observing = scrape_meta.gauge('node_scrape_collector_observing',
		'Whether a collector had something to observe: 0 when its hardware, kernel feature or service is not there.');
	for (let i, r in runs)
		observing(labels[i], !Result.is_none(r.result));

	let held = scrape_meta.gauge(QUARANTINED,
		'Whether a collector is quarantined: its circuit breaker tripped, and it is not run until its cool-down is over.');
	for (let i, r in runs)
		held(labels[i], r.skipped == 'quarantine');

	// Whatever the query selects, as node_exporter's node_exporter_build_info.
	scrape_meta.gauge(BUILD_INFO,
		'A metric with a constant \'1\' value labeled by the version of ucode-prometheus-exporter.')({ version: env.version }, 1);

	// A family is one collector's (ownership.own): the reply is each one's text,
	// in the order selected, then the scrape's own.
	let body = join('', map(runs, (r) => r.text ?? '')) + exposition.render(scrape_meta.families());

	progress?.finish();

	if (st) {
		let written = { seconds: seconds(t1, env.clock()), samples: 0 };

		for (let r in runs)
			written.samples += r.samples;

		let events = [];

		st.update(ledger.NAME, function(text) {
			events = [];
			return ledger.serialize(ledger.record(ledger.parse(text), runs, written, ids, events));
		});
		log_breakers(env, events);
	}

	return reply('200 OK', body);
};
