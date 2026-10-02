#!/usr/bin/ucode
'use strict';

// `service prometheus-exporter check`; --config checks the
// configuration alone, as start and reload do. See prometheus_exporter.check.

import * as deps from 'prometheus_exporter.deps';
import * as jail from 'prometheus_exporter.jail';
import * as check from 'prometheus_exporter.check';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';
import { load, scrape_env } from 'prometheus_exporter.app';

const config_only = ARGV[0] == '--config';

if (length(ARGV) > (config_only ? 1 : 0)) {
	warn('usage: check.uc [--config]\n');
	exit(2);
}

const mods = deps.modules();
const skipped = [];
const quiet = () => null;
const collectors = load(mods, null, (level, msg) => push(skipped, msg));

// The running instance's: the service's own scrapes.
const st = state.latest(mods.fs, state.DIR);

const res = check.run({
	uci: mods.uci.cursor(),
	fs: mods.fs,
	path: jail.PATH,
	collectors,
	skipped,
	ledger: st ? ledger.parse(st.read(ledger.NAME)) : null,
	env: scrape_env(mods, quiet),
}, { config_only });

print(res.report, '\n');
exit(res.ok ? 0 : 1);
