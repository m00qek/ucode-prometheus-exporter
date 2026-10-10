#!/usr/bin/ucode
'use strict';

import { mkdir, chmod, chown, open, readfile, rename, unlink, stat, error } from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as jail from 'prometheus_exporter.jail';
import * as state from 'prometheus_exporter.state';
import * as privileges from 'prometheus_exporter.privileges';
import * as grant from 'prometheus_exporter.grant';
import { load } from 'prometheus_exporter.app';

const mode = ARGV[0];

if (length(ARGV) > 1 || (mode != null && !(mode in [ '--missing', '--make', '--clean' ]))) {
	warn('usage: jail.uc [--missing|--make|--clean]\n');
	exit(2);
}

const fs_all = { stat, readfile, open, chown, chmod, rename, unlink, error };
const priv = {
	fs: fs_all,
	reload_ubus: () => system([ 'killall', '-HUP', 'ubusd' ]) == 0,
	lock: function() {
		let h = open(privileges.GROUP_LOCK, 'a');

		h?.lock('x');
		return () => h?.close();
	},
};

if (mode == '--clean')
	exit(grant.clean(priv) ? 0 : 1);

const mods = deps.modules();
const log = (msg) => warn(`${msg}\n`);
const quiet = () => null;
const collectors = load(mods, null, quiet);
const res = jail.mounts(collectors, { uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH });

if (mode == '--missing') {
	for (let p in res.missing)
		print(p, '\n');
	exit(0);
}

if (mode == '--make') {
	let made = jail.make({ ...mods.fs, mkdir, error }, res.owned);
	let st = state.make({ ...mods.fs, mkdir, chmod, chown, error }, privileges.USER);
	let granted = grant.make(priv, jail.grants(collectors, { uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH }));

	for (let p in made.made)
		print(`made ${p}\n`);
	for (let p in granted.made)
		print(`${p}\n`);
	if (!st.ok)
		push(made.problems, st.problem);
	push(made.problems, ...granted.problems);
	for (let p in made.problems)
		log(p);
	exit(length(made.problems) ? 1 : 0);
}

for (let p in res.problems)
	log(p);

print(join('\n', uniq([ ...jail.SERVICE, ...res.mounts ])), '\n');
