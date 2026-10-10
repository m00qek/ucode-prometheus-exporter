#!/usr/bin/ucode
'use strict';

import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import * as scrape from 'prometheus_exporter.scrape';
import * as deadline from 'prometheus_exporter.deadline';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';
import { load, scrape_env } from 'prometheus_exporter.app';

const mode = ARGV[0];

if (!(mode in [ 'scrape', 'runs' ]) || length(ARGV) > ((mode == 'scrape') ? 2 : 1)) {
	warn('usage: trial.uc scrape [QUERY] | trial.uc runs\n');
	exit(2);
}

const mods = deps.modules();
const logs = [];
const skipped = [];
const log = (level, msg) => push(logs, [ level, msg ]);
const collectors = load(mods, null, (level, msg) => push(skipped, msg));
const env = scrape_env(mods, log, { tmp: state.DIR });
const uci = mods.uci.cursor();

if (mode == 'scrape') {
	let main = config.main(uci);
	let budget = deadline.budget(main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT);
	let res = scrape.scrape(env, collectors, ARGV[1] ?? '', { deadline: deadline.seconds(clock(true)) + budget, budget });

	printf('%J\n', { status: res.status, body: res.body, logs: [ ...map(skipped, (m) => [ 'err', m ]), ...logs ] });
	exit(0);
}

const st = state.latest(mods.fs, state.DIR);
const chosen = filter(collectors, (c) => config.enabled(uci, c.id));
const runs = scrape.trial(env, uci, st ? ledger.parse(st.read(ledger.NAME)) : null, chosen, collectors);

printf('%J\n', {
	runs: map(runs, (r) => ({
		name: r.name, id: r.id, duration: r.duration, samples: r.samples,
		result: { ok: r.result.ok, error: r.result.error, details: r.result.details, none: r.result.none },
	})),
	skipped,
	logs,
});
