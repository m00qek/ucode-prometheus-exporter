/**
 * One scrape: run the collectors the query asks for, and write the reply.
 *
 * @module prometheus_exporter_scrape
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as exposition from 'prometheus.exporter.exposition';
import * as config from 'prometheus.exporter.config';
import * as query from 'prometheus.exporter.query';
import { seconds as now_of, budget as deadline_budget } from 'prometheus.exporter.deadline';
import * as ledger from 'prometheus.exporter.ledger';
import * as runner from 'prometheus.exporter.runner';
import { pid_of, SIZE_MAX } from 'prometheus.exporter.state';
import { own } from 'prometheus.exporter.ownership';
import { bury, log_breakers } from 'prometheus.exporter.progress';

/**
 * The env a scrape runs collectors in (app.scrape_env makes it).
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
 *   open: ?function(string, ?string): ?FsFile,
 *   readfile: ?function(string): ?string,
 *   kill: ?function(int): void,
 *   exit: ?function(int): void
 * }} ScrapeEnv
 */

/**
 * A collector's run, as run_one, not_run and the runner give it.
 *
 * @typedef {{
 *   name: string,
 *   id: string,
 *   result: Result,
 *   families: (RecordedFamily|string)[],
 *   samples: int,
 *   duration: float,
 *   budget: ?int,
 *   skipped: ?string,
 *   text: ?string
 * }} Run
 */

/**
 * A scrape's reply: its status line, content type and body.
 *
 * @typedef {{ status: string, content_type: string, body: string }} ScrapeReply
 */

/**
 * scrape()'s options: the deadline, the seconds it left, the state.
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
 *   progress: ?ProgressFile,
 *   omit: ?boolean,
 *   main: ?Result<MainSettings>
 * }} CollectOptions
 */

/** The content type of a scrape's reply: the text exposition format, 0.0.4. */
export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

/** The family that says the exporter's version. */
export const BUILD_INFO = 'ucode_prometheus_exporter_build_info';

/** The family that says whether a collector is quarantined. */
export const QUARANTINED = 'ucode_prometheus_exporter_collector_quarantined';

function seconds(t1, t2) {
	return (t2[0] - t1[0]) + (t2[1] - t1[1]) / 1000000000.0;
}

/**
 * The collectors a query string selects, in the order it names them.
 *
 * @param {Collector[]} collectors
 * @param {?string} query_string
 * @param {?string[]} disabled
 * @returns {Result<Collector[]>}
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

function over_limit(over, max) {
	return Result.err(errors.SAMPLE_LIMIT,
		sprintf('more than its max_samples of %d: stopped at %d samples, in %s', max, over.samples, over.family));
}

function over_reply(over, left) {
	return Result.err(errors.SAMPLE_LIMIT,
		sprintf('more than the %d samples left of the reply\'s max_scrape_samples: stopped at %d samples, in %s', left, over.samples, over.family),
		{ scrape: true });
}

function refused(bad) {
	let where = (bad.family != null) ? `in ${bad.family}` : 'in out.labels()';

	if (bad.label != null)
		where += `, label '${bad.label}'`;

	return Result.err(errors.EXPOSITION_INVALID, `${where}: ${bad.why}`);
}

/**
 * Runs one collector, within its budget and sample limit.
 *
 * @param {ScrapeEnv} env
 * @param {Session} session
 * @param {Collector} collector
 * @param {?Job} job
 * @returns {Run}
 */
export function run_one(env, session, collector, job) {
	let t1 = env.clock();
	let settings = job?.settings;
	let res = null;

	if (settings == null) {
		res = config.settings(session.uci(), collector.id, collector.meta);
		settings = res.ok ? res.data : null;
	}

	let budget = settings?.budget;
	let max = settings?.max_samples;
	let left = job?.left;
	let reply_cap = (left != null && (max == null || left < max));
	let rec = exposition.recorder(reply_cap ? left : max);

	if (settings != null) {
		res = session.for(collector.meta, settings, job?.cutoff, job?.view, job?.limit);
		if (res.ok) {
			try {
				let r = collector.collect(res.data, rec, settings.options);
				res = Result.is(r) ? r : Result.err(errors.COLLECTOR_NO_RESULT, `returned ${type(r) ?? 'null'}`);
			} catch (e) {
				res = Result.err(errors.COLLECTOR_CRASHED, split(e.message, '\n')[0]);
			}

			session.done?.();

			if (!res.ok && (type(res.error) != 'string' || res.error == ''))
				res = Result.err(errors.COLLECTOR_NO_RESULT,
					'failed without an error code' + ((res.details != null) ? `: ${res.details}` : ''), res.data);
		}
	}

	let duration = seconds(t1, env.clock());
	let over = rec.over();
	let bad = rec.invalid();

	if (over)
		res = reply_cap ? over_reply(over, left) : over_limit(over, max);
	else if (bad)
		res = refused(bad);

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
 * A collector left out, without running.
 *
 * @param {Collector} collector
 * @param {Result} res
 * @param {string} why
 * @returns {Run}
 */
export function not_run(collector, res, why) {
	return { name: collector.meta.name, id: collector.id, result: res, families: [], samples: 0, duration: 0, skipped: why };
};

function at_deadline(r) {
	return r.result.error == errors.SCRAPE_DEADLINE;
}

/**
 * The line logged of the collectors the deadline left out or cut, or null.
 *
 * @param {Run[]} runs
 * @param {float} budget
 * @returns {?string}
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

const OWN_FAMILIES = [
	[ 'node_scrape_collector_duration_seconds', 'node_exporter: Duration of a collector scrape.' ],
	[ 'node_scrape_collector_success', 'node_exporter: Whether a collector succeeded.' ],
	[ 'node_scrape_collector_observing',
		'Whether a collector had something to observe: 0 when its hardware, kernel feature or service is not there.' ],
	[ QUARANTINED, 'Whether a collector is quarantined: its circuit breaker tripped, and it is not run until its cool-down is over.' ],
	[ BUILD_INFO, 'A metric with a constant \'1\' value labeled by the version of ucode-prometheus-exporter.' ],
];

function own_header(i) {
	let f = OWN_FAMILIES[i];

	return `# HELP ${f[0]} ${f[1]}\n# TYPE ${f[0]} gauge\n`;
}

/**
 * The scrape's own families, as the reply ends with them.
 *
 * @param {Run[]} runs
 * @param {string} version
 * @returns {string}
 */
export function own_text(runs, version) {
	let parts = [ [], [], [], [] ];

	for (let r in runs) {
		let name = r.name;

		if (index(name, '\\') >= 0 || index(name, '"') >= 0 || index(name, '\n') >= 0)
			name = exposition.escape_label(name);

		let label = '{collector="' + name + '"} ';
		let v = r.duration;
		let d = '' + v;

		if (type(v) != 'int' && (type(v) != 'double' || +d != v || v - v != 0))
			d = exposition.format_value(v);

		if (d != null)
			push(parts[0], 'node_scrape_collector_duration_seconds' + label + d);
		push(parts[1], 'node_scrape_collector_success' + label + (r.result.ok ? '1' : '0'));
		push(parts[2], 'node_scrape_collector_observing' + label + ((r.result.ok === true && r.result.none != null) ? '0' : '1'));
		push(parts[3], QUARANTINED + label + ((r.skipped == 'quarantine') ? '1' : '0'));
	}

	let text = '';

	for (let i, p in parts)
		if (length(p))
			text += own_header(i) + join('\n', p) + '\n';

	let label = (version != null) ? `{version="${exposition.escape_label('' + version)}"}` : '';

	return text + own_header(4) + `${BUILD_INFO}${label} 1\n`;
};

/** The exporter's own collector: a scrape that runs it writes the ledger's counters and each collector's samples. */
export const EXPORTER = 'exporter';

/**
 * The ledger's counters, by collector name, and each run's samples, as the scrape writes them after its runs.
 *
 * @param {?LedgerCounters} n
 * @param {Run[]} runs
 * @param {?boolean} omit
 * @returns {string}
 */
export function exporter_text(n, runs, omit) {
	let out = exposition.recorder();

	if (n != null) {
		out.batch('counter', [
			[ 'ucode_prometheus_exporter_scrapes_total', 'Scrapes the exporter answered since the service started.', n.scrapes ],
			[ 'ucode_prometheus_exporter_auth_failures_total', 'Requests basic auth refused since the service started.', n.auth_failures ],
		]);

		let failures = out.counter('ucode_prometheus_exporter_collector_failures_total', 'Scrapes in which a collector failed, by its error code, since the service started.');
		let timeouts = out.counter('ucode_prometheus_exporter_program_timeouts_total', 'Programs of a collector killed at their timeout since the service started.');
		let quarantines = out.counter('ucode_prometheus_exporter_quarantines_total', 'Times a collector\'s circuit breaker tripped since the service started.');
		let skips = out.counter('ucode_prometheus_exporter_deadline_skips_total', 'Scrapes whose deadline left a collector out, or killed its program, since the service started.');

		for (let name in sort(keys(n.collectors))) {
			let c = n.collectors[name];
			let labels = out.labels({ collector: name });

			for (let code in sort(keys(c.failures)))
				failures({ collector: name, reason: code }, c.failures[code]);
			timeouts(labels, c.timeouts);
			quarantines(labels, c.quarantines);
			skips(labels, c.deadline_skips);
		}
	}

	let written = out.gauge('ucode_prometheus_exporter_collector_samples', 'Samples a collector wrote in this scrape.');
	let samples = {};

	for (let r in runs)
		samples[r.name] = r.samples;
	for (let name in sort(keys(samples)))
		written({ collector: name }, samples[name]);

	return exposition.pack(out.families(), omit).text;
};

function too_late(l, c, now, cutoff) {
	let need = ledger.estimate(l, c.id);

	if (now >= cutoff)
		return Result.err(errors.SCRAPE_DEADLINE, 'not run: the scrape\'s time was spent');
	if (need != null && now + need >= cutoff)
		return Result.err(errors.SCRAPE_DEADLINE, sprintf('not run: it takes %.2f s, and %.2f s were left', need, cutoff - now));

	return null;
}

function untimed_rank(c) {
	return 1 + (c.own ? 0 : 2) + ((c.meta.cost == 'heavy') ? 1 : 0);
}

function runner_of(env, chosen, omit, deadline) {
	return env.fork
		? runner.forked(env, run_one, { collectors: chosen, omit, stats: env.stats, tmp: env.tmp, deadline })
		: runner.inline(env, run_one, { omit });
}

/**
 * Runs the `chosen` collectors, fastest first by the ledger: each run, by id.
 *
 * @param {ScrapeEnv} env
 * @param {UciCursor} uci
 * @param {Ledger} l
 * @param {Collector[]} chosen
 * @param {?CollectOptions} opts
 * @returns {Object<string, Run>}
 */
export function collect(env, uci, l, chosen, opts) {
	let by_id = {};
	let collected = 0;
	let m = ledger.number(l);
	let deadline = opts?.deadline;
	let queue = ledger.order(l, chosen, null, untimed_rank);
	let next = 0;
	let place = {};
	let main = opts?.main ?? config.main(uci);
	let reply_max = main.ok ? main.data.max_scrape_samples : config.MAX_SCRAPE_SAMPLES;

	for (let i, c in queue)
		place[c.id] = i;

	let plan = {
		next: function(log) {
			if (next >= length(queue))
				return null;

			let c = queue[next++];

			if (opts?.quarantine && ledger.phase(l, c.id, m) == 'open')
				return { c, skipped: not_run(c, ledger.quarantined(l, c.id, m), 'quarantine') };

			let now = now_of(env.clock());
			let cutoff = null;

			if (deadline != null) {
				cutoff = deadline - ledger.writing(l, collected + ledger.samples(l, c.id));

				let late = too_late(l, c, now, cutoff);

				if (late)
					return { c, skipped: not_run(c, late, 'deadline') };
			}

			let left = reply_max - collected;

			if (left <= 0) {
				let full = Result.err(errors.SAMPLE_LIMIT,
					sprintf('not run: the reply has its max_scrape_samples of %d', reply_max), { scrape: true });

				log('warning', `collector '${c.meta.name}': ${Result.describe(full)}`);
				return { c, skipped: not_run(c, full, 'samples') };
			}

			let s = config.settings(uci, c.id, c.meta, main);
			let budget = s.ok ? s.data.budget : null;
			let limit = (budget != null) ? now + budget : null;
			let held = false;

			if (cutoff != null && (limit == null || cutoff < limit)) {
				limit = cutoff;
				held = true;
			}

			return {
				c, cutoff, limit, at_deadline: held, budget, left,
				settings: s.ok ? s.data : null,
				view: ('exporter' in c.meta.needs) ? { pid: opts?.pid } : null,
			};
		},
		started: (job, pid) => opts?.progress?.start(job.c.id, pid),
		done: function(job, r) {
			next = max(next, place[job.c.id] + 1);
			collected += r.samples;
			by_id[job.c.id] = r;
		},
	};

	let signal = runner_of(env, chosen, opts?.omit, deadline).run(plan);

	if (signal) {
		let quit = env.exit ?? exit;

		env.log('notice', `asked to stop (signal ${signal}) while it ran the collectors: stopping`);
		opts?.progress?.finish();
		quit(128 + signal);
	}

	let by_c = {};

	for (let c in chosen) {
		by_c[c.id] = c;
		by_id[c.id] ??= not_run(c, Result.err(errors.COLLECTOR_NOT_RUN, 'not run: the scrape was handed no run of it'), 'runner');
	}

	own(env, map(chosen, (c) => by_id[c.id]), by_c);

	return by_id;
};

/**
 * A guarded run of `chosen` outside the service's scrapes.
 *
 * @param {ScrapeEnv} env
 * @param {UciCursor} uci
 * @param {?Ledger} l
 * @param {Collector[]} chosen
 * @param {?Collector[]} installed
 * @returns {Run[]}
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
 * { status, content_type, body } for a scrape with this query string.
 *
 * @param {ScrapeEnv} env
 * @param {Collector[]} collectors
 * @param {?string} query_string
 * @param {?ScrapeOptions} opts
 * @returns {ScrapeReply}
 */
export function scrape(env, collectors, query_string, opts) {
	let session = env.session();
	let uci = session.uci();
	let disabled = config.disabled(uci, map(collectors, (c) => c.id));
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

	let kept = st?.read(ledger.NAME);
	let l = ledger.parse(kept);
	let progress = st?.progress ? st.progress() : null;
	let by_id = collect(env, uci, l, sel.data, {
		deadline: opts?.deadline, quarantine: true, collectors, pid: st ? pid_of(st.id) : null,
		progress, omit: main.data.omit_zero_values, main: main_read,
	});
	let runs = map(sel.data, (c) => by_id[c.id]);

	progress?.collected();
	session.close();

	let late = deadline_line(runs, opts?.budget ?? 0);
	if (late)
		env.log('warning', late);

	let t1 = env.clock();

	let ex = filter(sel.data, (c) => c.own && c.id == EXPORTER)[0];
	let self = '';

	if (ex != null) {
		let named = null;

		if (st) {
			let n = ledger.counters_with(l, runs, ids);

			named = { ...n, collectors: {} };
			for (let c in collectors)
				if (n.collectors[c.id] != null)
					named.collectors[c.meta.name] = n.collectors[c.id];
		}

		self = exporter_text(named, runs, main.data.omit_zero_values);
	}

	let body = join('', map(runs, (r) => (r.text ?? '') + ((r.id == ex?.id) ? self : ''))) + own_text(runs, env.version);

	progress?.finish();

	if (st) {
		let written = { seconds: seconds(t1, env.clock()), samples: 0 };

		for (let r in runs)
			written.samples += r.samples;

		let events = [];

		let recorded = st.update(ledger.NAME, function(text) {
			events = [];
			return ledger.serialize(ledger.record((text == kept) ? l : ledger.parse(text), runs, written, ids, events), SIZE_MAX);
		});

		if (!recorded)
			env.log('warning', 'the scrape could not be recorded in the instance\'s state: its ledger is as the last scrape left it');
		log_breakers(env, events);
	}

	return reply('200 OK', body);
};
