'use strict';

// One scrape: pick the collectors the query asks for, run each with its deps and
// options, time it, and write every family once, followed by node_exporter's
// node_scrape_collector_duration_seconds and node_scrape_collector_success.
//
// env: { session() -> a deps session, clock() -> [ s, ns ] monotonic, log(msg) }

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import * as exposition from 'node_exporter.exposition';
import * as config from 'node_exporter.config';
import * as query from 'node_exporter.query';

export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

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

// Runs one collector: { name, result, families, duration }. What it recorded is
// kept even when it fails, as upstream exporters do.
export function run_one(env, session, c) {
	let rec = exposition.recorder();
	let t1 = env.clock();
	let res = config.collector(session.uci(), c.id, c.meta.options);

	if (res.ok) {
		let options = res.data;

		res = session.for(c.meta);
		if (res.ok) {
			try {
				let r = c.collect(res.data, rec, options);
				res = Result.is(r) ? r : Result.err(errors.COLLECTOR_NO_RESULT, `returned ${type(r) ?? 'null'}`);
			} catch (e) {
				res = Result.err(errors.COLLECTOR_CRASHED, split(e.message, '\n')[0]);
			}
		}
	}

	let duration = seconds(t1, env.clock());

	if (!res.ok)
		env.log(`collector '${c.meta.name}': ${Result.describe(res)}`);
	for (let name in rec.conflicts())
		env.log(`collector '${c.meta.name}': '${name}' declared with two types; later samples dropped`);

	return { name: c.meta.name, result: res, families: rec.families(), duration };
};

function reply(status, body) {
	return { status, content_type: CONTENT_TYPE, body };
}

// { status, content_type, body } for a scrape with this query string.
export function scrape(env, collectors, query_string) {
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
		env.log(`main: ${Result.describe(main)}`);
		main = Result.ok(config.defaults(config.MAIN_OPTIONS));
	}

	let runs = map(sel.data, (c) => run_one(env, session, c));
	session.close();

	let scrape_meta = exposition.recorder();
	let duration = scrape_meta.gauge('node_scrape_collector_duration_seconds',
		'node_exporter: Duration of a collector scrape.');
	let success = scrape_meta.gauge('node_scrape_collector_success',
		'node_exporter: Whether a collector succeeded.');

	for (let r in runs)
		duration({ collector: r.name }, r.duration);
	for (let r in runs)
		success({ collector: r.name }, r.result.ok);

	let merged = exposition.merge([ ...map(runs, (r) => r.families), scrape_meta.families() ]);
	for (let name in merged.conflicts)
		env.log(`'${name}' declared with two types by different collectors; later samples dropped`);

	return reply('200 OK', exposition.render(merged.families, { omit_zero_counters: main.data.omit_zero_values }));
};
