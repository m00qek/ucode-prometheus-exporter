#!/usr/bin/ucode
'use strict';

// The paths the exporter's jail mounts for the installed and enabled
// collectors, one per line, for /etc/init.d/prometheus-exporter; what cannot be
// mounted goes to standard error. With --missing, the paths those collectors
// read that are not there yet instead. See prometheus_exporter.jail.

import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as jail from 'prometheus_exporter.jail';

const missing = ARGV[0] == '--missing';

if (length(ARGV) > (missing ? 1 : 0)) {
	warn('usage: jail.uc [--missing]\n');
	exit(2);
}

const mods = deps.modules();
const log = (msg) => warn(`${msg}\n`);
const collectors = loader.load(mods.fs, loader.DIR, loader.import_module, log);
const res = jail.mounts(collectors, { uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH });

if (missing) {
	for (let p in res.missing)
		print(p, '\n');
	exit(0);
}

for (let p in res.problems)
	log(p);

print(join('\n', res.mounts), '\n');
