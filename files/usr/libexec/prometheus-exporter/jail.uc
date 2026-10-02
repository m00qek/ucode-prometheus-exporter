#!/usr/bin/ucode
'use strict';

// The paths the exporter's jail mounts for the installed and enabled
// collectors, one per line, for /etc/init.d/prometheus-exporter; what cannot be
// mounted goes to standard error. With --missing, the paths those collectors
// read that are not there yet instead. With --make, it makes the directories
// those collectors own (textfile's) that are not there, and says which, and
// the exporter's state directory (mode 0700, which the jail mounts read-write;
// see prometheus_exporter.state), and what it could not make on standard
// error. The init script logs each at its own priority. See
// prometheus_exporter.jail.

import { mkdir, chmod, error } from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as jail from 'prometheus_exporter.jail';
import * as state from 'prometheus_exporter.state';
import { load } from 'prometheus_exporter.app';

const mode = ARGV[0];

if (length(ARGV) > 1 || (mode != null && !(mode in [ '--missing', '--make' ]))) {
	warn('usage: jail.uc [--missing|--make]\n');
	exit(2);
}

const mods = deps.modules();
const log = (msg) => warn(`${msg}\n`);
const quiet = () => null;
// The handler logs a collector that does not load; here it is only left out.
const collectors = load(mods, null, quiet);
const res = jail.mounts(collectors, { uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH });

if (mode == '--missing') {
	for (let p in res.missing)
		print(p, '\n');
	exit(0);
}

if (mode == '--make') {
	let made = jail.make({ ...mods.fs, mkdir, error }, res.owned);
	let st = state.make({ ...mods.fs, mkdir, chmod, error });

	for (let p in made.made)
		print(`made ${p}\n`);
	if (!st.ok)
		push(made.problems, st.problem);
	for (let p in made.problems)
		log(p);
	exit(length(made.problems) ? 1 : 0);
}

for (let p in res.problems)
	log(p);

print(join('\n', res.mounts), '\n');
