#!/usr/bin/ucode
'use strict';

// `service prometheus-exporter check`; --config checks the
// configuration alone, as start and reload do. See prometheus_exporter.check.

import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as jail from 'prometheus_exporter.jail';
import * as check from 'prometheus_exporter.check';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';

const config_only = ARGV[0] == '--config';

if (length(ARGV) > (config_only ? 1 : 0)) {
	warn('usage: check.uc [--config]\n');
	exit(2);
}

const mods = deps.modules();
const skipped = [];
const quiet = () => null;
const collectors = loader.load(mods.fs, loader.DIR, loader.import_module, (msg) => push(skipped, msg));

// The running instance's: the service's own scrapes.
const st = state.latest(mods.fs, state.DIR);

const res = check.run({
	uci: mods.uci.cursor(),
	fs: mods.fs,
	path: jail.PATH,
	collectors,
	skipped,
	ledger: st ? ledger.parse(st.read(ledger.NAME)) : null,
	env: {
		session: () => deps.session({ ...mods, log: quiet }),
		clock: () => clock(true),
		log: quiet,
	},
}, { config_only });

print(res.report, '\n');
exit(res.ok ? 0 : 1);
