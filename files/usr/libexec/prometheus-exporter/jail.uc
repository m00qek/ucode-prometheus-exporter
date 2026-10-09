#!/usr/bin/ucode
'use strict';

// The paths the exporter's jail mounts read-only, one per line, for
// /etc/init.d/prometheus-exporter: the service's own (jail.SERVICE, some of
// them globs), then what the installed and enabled collectors get, the ubus
// socket among them when one needs ubus; what cannot be mounted goes to
// standard error. With --missing, the paths those collectors
// read that are not there yet instead. With --make, it makes the directories
// those collectors own (textfile's) that are not there, and says which, and
// the exporter's state directory (mode 0700, the service's user's, which the
// jail mounts read-write; see prometheus_exporter.state), and grants the
// service's user what those collectors declare (prometheus_exporter.
// privileges: the ubus ACL, the capabilities file, its groups, read access to
// configs and proc files, the TLS copies); what it could not do goes to
// standard error. With --clean, as the service stops, it takes away the ACL,
// the capabilities file and the TLS copies. The init script logs each at its
// own priority. See prometheus_exporter.jail.

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

// What grant.make and clean take of the system: ubusd reads its ACLs
// again on SIGHUP, and /etc/group is changed under the lock OpenWrt's tools
// take (lock /var/lock/passwd, an flock()).
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
