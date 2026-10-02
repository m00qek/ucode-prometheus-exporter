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
// env: { session() -> a deps session, clock() -> [ s, ns ] monotonic,
//        log(level, msg): a collector that fails at warning, as the scrape
//        answers without it; a main section the exporter cannot read at err,
//        version: the exporter's version (prometheus_exporter.version) }

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as exposition from 'prometheus_exporter.exposition';
import * as config from 'prometheus_exporter.config';
import * as query from 'prometheus_exporter.query';
import { seconds as now_of } from 'prometheus_exporter.deadline';
import * as ledger from 'prometheus_exporter.ledger';

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

// Runs one collector: { name, id, result, families, samples, duration,
// budget }, budget the seconds it may take (config.settings). What it
// recorded is kept even when it fails, as upstream exporters do; nothing is
// when it has nothing to observe. Its programs never run past `cutoff`
// (monotonic seconds), when given.
export function run_one(env, session, c, cutoff) {
	let rec = exposition.recorder();
	let t1 = env.clock();
	let res = config.settings(session.uci(), c.id, c.meta);
	let budget = res.ok ? res.data.budget : null;

	if (res.ok) {
		let settings = res.data;

		res = session.for(c.meta, settings, cutoff);
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

	// One cut at the deadline is in the scrape's line of them.
	if (!res.ok && res.error != errors.SCRAPE_DEADLINE)
		env.log('warning', `collector '${c.meta.name}': ${Result.describe(res)}`);
	for (let name in rec.conflicts())
		env.log('warning', `collector '${c.meta.name}': '${name}' declared with two types; later samples dropped`);

	let families = Result.is_none(res) ? [] : rec.families();
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

// The line the scrape logs of the collectors the deadline left out or cut, or
// null for none.
export function deadline_line(runs, budget) {
	let names = map(filter(runs, (r) => r.result.error == errors.SCRAPE_DEADLINE), (r) => r.name);

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

// Runs the selected collectors, fastest first by the ledger `l`: each one's
// run, by id. One whose breaker is open does not run. With a deadline, a
// collector runs only if the ledger expects it done in time to write the
// reply, its own samples included; its programs never run past that.
function run_all(env, session, l, chosen, deadline) {
	let by_id = {};
	let collected = 0;
	let m = ledger.number(l);

	for (let c in ledger.order(l, chosen)) {
		let r;

		if (ledger.phase(l, c.id, m) == 'open') {
			r = not_run(c, ledger.quarantined(l, c.id, m), 'quarantine');
		} else if (deadline == null) {
			r = run_one(env, session, c);
		} else {
			let cutoff = deadline - ledger.writing(l, collected + ledger.samples(l, c.id));
			let late = too_late(l, c, now_of(env.clock()), cutoff);

			r = late ? not_run(c, late, 'deadline') : run_one(env, session, c, cutoff);
		}

		collected += r.samples;
		by_id[c.id] = r;
	}

	return by_id;
}

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
	let l = ledger.parse(st?.read(ledger.NAME));
	let by_id = run_all(env, session, l, sel.data, opts?.deadline);
	let runs = map(sel.data, (c) => by_id[c.id]);

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

	if (st) {
		let written = { seconds: seconds(t1, env.clock()), samples: 0 };
		let ids = map(collectors, (c) => c.id);

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
