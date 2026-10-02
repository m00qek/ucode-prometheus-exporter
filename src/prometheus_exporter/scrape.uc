'use strict';

// One scrape: pick the collectors the query asks for, run each with its deps and
// options, time it, and write every family once, followed by node_exporter's
// node_scrape_collector_duration_seconds and node_scrape_collector_success,
// node_scrape_collector_observing, and the exporter's own
// ucode_prometheus_exporter_collector_quarantined and
// ucode_prometheus_exporter_build_info.
//
// A collector with nothing to observe (Result.none: its hardware, kernel
// feature or service is not there) succeeds, writes no samples and is not
// logged: it is what the device is, every scrape. Its
// node_scrape_collector_observing is 0, so a dashboard tells it from one that
// observes and finds nothing to count; every other collector's is 1.
//
// The handler's scrapes keep a ledger in the instance's state
// (prometheus_exporter.ledger): how long each collector took, how many
// samples it wrote, and its circuit breaker (prometheus_exporter.breaker).
// They run the collectors fastest first by it, so that a deadline leaves out
// the few slow ones rather than the many fast ones; the reply has them in the
// order the query selects, whatever order they ran in. A collector whose
// breaker is open is not run, even when the query names it: it fails with
// COLLECTOR_QUARANTINED, and its ucode_prometheus_exporter_collector_quarantined
// is 1. The scrape logs a breaker that trips or closes, not each scrape that
// leaves a collector out.
//
// A scrape may have a deadline (prometheus_exporter.deadline): it then starts
// no collector the ledger does not expect done in time to write the reply,
// and none of their programs runs past that. A collector left out so fails
// with SCRAPE_DEADLINE, as one whose program was killed at the deadline does,
// and the scrape logs them once, all together, not a line each.
//
// Each collector runs as prometheus_exporter.runner runs it: with env.fork,
// in a child process of the scrape's, stopped at its limit (its budget's end,
// or the deadline) with the process, and a collector whose process dies under
// it fails alone; without, in this process, as the tests run it. It writes at
// most its max_samples (prometheus_exporter.exposition's recorder), and a
// family belongs to the first collector of the reply that writes it: another
// that writes it fails with FAMILY_CONFLICT (own()). A collector that breaks
// one of these rules, or is stopped, fails, and none of its samples are
// served.
//
// env: { session(log) -> a deps session, its collectors' lines logged with
//        log when given, clock() -> [ s, ns ] monotonic,
//        log(level, msg): a collector that fails at warning, as the scrape
//        answers without it; a main section the exporter cannot read at err,
//        version: the exporter's version (prometheus_exporter.version),
//        fork: whether to run the collectors in child processes,
//        tmp: the directory of the file their runs cross by (runner.forked),
//        stats: an object the runner fills in, for the benchmark }

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

export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

export const BUILD_INFO = 'ucode_prometheus_exporter_build_info';
export const QUARANTINED = 'ucode_prometheus_exporter_collector_quarantined';

function seconds(t1, t2) {
	return (t2[0] - t1[0]) + (t2[1] - t1[1]) / 1000000000.0;
}

// The collectors a query string selects, in the order it names them (all the
// enabled ones when it names none), less the excluded. Naming an unknown or a
// disabled collector is an error; `disabled` holds the module names of those
// switched off in the config.
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

// Runs one collector: { name, id, result, families, samples, duration,
// budget }, budget the seconds it may take (config.settings). What it
// recorded is kept even when it fails, as upstream exporters do; nothing is
// when it has nothing to observe, nor when it wrote more than its
// max_samples, which it fails with SAMPLE_LIMIT. job (prometheus_exporter.
// runner's), when given: its programs never run past job.cutoff (monotonic
// seconds), its ubus calls past job.limit; job.settings are its settings,
// read already; job.view is the exporter collector's.
export function run_one(env, session, c, job) {
	let t1 = env.clock();
	let res = job?.settings ? Result.ok(job.settings) : config.settings(session.uci(), c.id, c.meta);
	let budget = res.ok ? res.data.budget : null;
	let max = res.ok ? res.data.max_samples : null;
	let rec = exposition.recorder(max);

	if (res.ok) {
		let settings = res.data;

		res = session.for(c.meta, settings, job?.cutoff, job?.view, job?.limit);
		if (res.ok) {
			try {
				let r = c.collect(res.data, rec, settings.options);
				res = Result.is(r) ? r : Result.err(errors.COLLECTOR_NO_RESULT, `returned ${type(r) ?? 'null'}`);
			} catch (e) {
				res = Result.err(errors.COLLECTOR_CRASHED, split(e.message, '\n')[0]);
			}
		}
	}

	let duration = seconds(t1, env.clock());
	let over = rec.over();

	// However it ended: it may have caught what stopped it.
	if (over)
		res = over_limit(over, max);

	// One cut at the deadline is in the scrape's line of them.
	if (!res.ok && res.error != errors.SCRAPE_DEADLINE)
		env.log('warning', `collector '${c.meta.name}': ${Result.describe(res)}`);
	for (let name in rec.conflicts())
		env.log('warning', `collector '${c.meta.name}': '${name}' declared with two types; later samples dropped`);

	let families = (Result.is_none(res) || over) ? [] : rec.families();
	let samples = 0;

	for (let f in families)
		samples += length(f.lines);

	return { name: c.meta.name, id: c.id, result: res, families, samples, duration, budget };
};

// A collector left out, without running: { name, id, result, families: [],
// samples: 0, duration: 0, skipped }.
export function not_run(c, res, why) {
	return { name: c.meta.name, id: c.id, result: res, families: [], samples: 0, duration: 0, skipped: why };
};

// The prefixes of the families the core writes: node_exporter's
// node_scrape_collector_* of every collector, and the exporter's own, which
// only a collector that describes the exporter (exporter in meta.needs) may
// write too.
export const SCRAPE_PREFIX = 'node_scrape_collector_';
export const EXPORTER_PREFIX = 'ucode_prometheus_exporter_';

function prefixed(name, prefix) {
	return substr(name, 0, length(prefix)) == prefix;
}

// Why collector `c` may not write family `name`, which `owners` ({ family:
// collector name }) says who wrote first, or null when it may.
function family_problem(c, name, owners) {
	if (prefixed(name, SCRAPE_PREFIX))
		return `${name} belongs to the scrape itself`;
	if (prefixed(name, EXPORTER_PREFIX) && !('exporter' in c.meta.needs))
		return `${name} belongs to the exporter itself`;
	if (owners[name] != null && owners[name] != c.meta.name)
		return `${name} belongs to collector ${owners[name]}`;

	return null;
}

// Each family to the first collector of `runs` (scrape.run_one's, in the
// order of the reply, `by_id` their collectors) that writes it: a run that
// writes a family another wrote first, or one the core keeps for itself,
// fails with FAMILY_CONFLICT, logged at warning, and none of its samples are
// served. The exporter's own collectors (loader.OWN) come first, then the
// others; each in the order of the reply, not the order they ran in, so the
// same collector wins every scrape, and one of another package never takes
// a family of the exporter's own. A family a collector writes is its own,
// and the reply has each once.
export function own(env, runs, by_id) {
	let owners = {};
	let first = filter(runs, (r) => r.id in loader.OWN);

	for (let r in [ ...first, ...filter(runs, (r) => !(r.id in loader.OWN)) ]) {
		let c = by_id[r.id];
		let why = null;

		for (let f in r.families) {
			why = family_problem(c, f.name, owners);
			if (why)
				break;
		}

		if (why) {
			r.result = Result.err(errors.FAMILY_CONFLICT, why);
			r.families = [];
			r.samples = 0;
			env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
			continue;
		}

		for (let f in r.families)
			owners[f.name] ??= r.name;
	}

	return runs;
};

// Whether a run was cut by the deadline: left out, its program killed there,
// or stopped there.
function at_deadline(r) {
	return r.result.error == errors.SCRAPE_DEADLINE;
}

// The line the scrape logs of the collectors the deadline left out or cut, or
// null for none.
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

// Runs the `chosen` collectors, fastest first by the ledger `l`: each one's
// run, by id. With `quarantine`, one whose breaker is open does not run. With
// a deadline, a collector runs only if the ledger expects it done in time to
// write the reply, its own samples included; its programs never run past that,
// and it is stopped there. Without one, or before it, it is stopped at its
// budget's end.
//
// A collector that needs `exporter` runs after every other, and sees the
// scrape so far: the ledger's counters with this scrape's runs, and their
// samples (deps.exporter_channel). opts: { deadline, quarantine,
// collectors: the installed ones, pid: the serving process's, null for this
// one, kept: whether the ledger is the instance's, progress: the scrape's
// (prometheus_exporter.state), omit: omit_zero_values }. The counters name
// collectors by their names.
export function collect(env, uci, l, chosen, opts) {
	let by_id = {};
	let collected = 0;
	let m = ledger.number(l);
	let installed = opts?.collectors ?? chosen;
	let ids = map(installed, (c) => c.id);
	let deadline = opts?.deadline;
	let queue = ledger.order(l, chosen, (c) => 'exporter' in c.meta.needs, untimed_rank);
	let next = 0;

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

				let s = config.settings(uci, c.id, c.meta);
				let budget = s.ok ? s.data.budget : null;
				let limit = (budget != null) ? now + budget : null;
				let held = false;

				if (cutoff != null && (limit == null || cutoff < limit)) {
					limit = cutoff;
					held = true;
				}

				opts?.progress?.start(c.id, pid);

				return {
					c, cutoff, limit, at_deadline: held, budget,
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

// A guarded run of `chosen` outside the service's scrapes: check, the ubus
// object's status, the command line's collector check. Each collector runs as
// the service's scrapes run it (env.fork: in a child process, stopped at its
// limit), with the deadline of a scrape whose scraper says no timeout (the
// main section's scrape_timeout), ordered by the service's ledger `l` (null
// for none), quarantined or not: it is there to see what each does now.
// `installed`: every collector, for the exporter's. Its runs, in the order
// of `chosen`; one the deadline left out has SCRAPE_DEADLINE.
export function trial(env, uci, l, chosen, installed) {
	let main = config.main(uci);
	let timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let by_id = collect(env, uci, l ?? ledger.empty(), chosen, {
		deadline: now_of(env.clock()) + deadline_budget(timeout), collectors: installed ?? chosen,
	});

	return map(chosen, (c) => by_id[c.id]);
};

// What changed of the breakers (ledger.record's events), logged: a breaker
// that tripped at warning, one that closed at notice.
function log_breakers(env, events) {
	for (let e in events) {
		if (e.tripped)
			env.log('warning', `collector '${e.name}' quarantined for ${e.cooldown} scrape${e.cooldown == 1 ? '' : 's'}: ${e.why}`);
		else if (e.closed)
			env.log('notice', `collector '${e.name}' served again: its trial succeeded`);
	}
}

// The collectors that were running when a scrape process of the instance
// died (prometheus_exporter.state's dead): each fails with COLLECTOR_KILLED,
// which trips its breaker, counted and logged at warning. A process that
// died once its collectors were done costs none of them. Each dead process
// is reckoned once, by the scrape that claims its progress file, under the
// state's lock. The child process its collector ran in, which nothing stops
// once the scrape that held its timer is gone, is killed (env.kill).
function bury(env, st, collectors) {
	let dead = st.dead();

	if (!length(dead))
		return;

	let names = {};
	let events = [];
	let blamed = [];

	for (let c in collectors)
		names[c.id] = c.meta.name;

	st.update(ledger.NAME, function(text) {
		let l = ledger.parse(text);

		events = [];
		blamed = [];
		for (let d in dead) {
			if (!st.claim(d.file))
				continue;
			if (d.running == null || names[d.running] == null)
				continue;

			push(blamed, names[d.running]);
			if (d.child && env.kill)
				env.kill(d.child.pid);
			l = ledger.killed(l, d.running, names[d.running],
				'its scrape process died while it ran: out of memory, a crash, or killed', events);
		}

		return ledger.serialize(l);
	});

	for (let name in blamed)
		env.log('warning', `collector '${name}' was running when a scrape process died`);
	log_breakers(env, events);
}

// { status, content_type, body } for a scrape with this query string. opts:
// { deadline: when the collectors must be done by (monotonic seconds),
//   budget: the seconds that left them, for the log,
//   state: the instance's state (prometheus_exporter.state), whose ledger
//          orders the collectors, says which ones the deadline has time
//          for and which ones their breakers keep out, and records this
//          scrape }.
// Whatever order they ran in, the reply has them in the order selected.
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
		progress, omit: main.data.omit_zero_values,
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

	for (let r in runs)
		duration({ collector: r.name }, r.duration);
	for (let r in runs)
		success({ collector: r.name }, r.result.ok);

	let observing = scrape_meta.gauge('node_scrape_collector_observing',
		'Whether a collector had something to observe: 0 when its hardware, kernel feature or service is not there.');
	for (let r in runs)
		observing({ collector: r.name }, !Result.is_none(r.result));

	let held = scrape_meta.gauge(QUARANTINED,
		'Whether a collector is quarantined: its circuit breaker tripped, and it is not run until its cool-down is over.');
	for (let r in runs)
		held({ collector: r.name }, r.skipped == 'quarantine');

	// Whatever the query selects, as node_exporter's node_exporter_build_info.
	scrape_meta.gauge(BUILD_INFO,
		'A metric with a constant \'1\' value labeled by the version of ucode-prometheus-exporter.')({ version: env.version }, 1);

	let merged = exposition.merge([ ...map(runs, (r) => r.families), scrape_meta.families() ]);
	for (let name in merged.conflicts)
		env.log('warning', `'${name}' declared with two types by different collectors; later samples dropped`);

	let body = exposition.render(merged.families, { omit_zero_counters: main.data.omit_zero_values });

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
