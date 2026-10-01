#!/usr/bin/ucode
'use strict';

// The paths the exporter's jail mounts for the installed and enabled
// collectors, one per line, for /etc/init.d/prometheus-node-exporter-ucode;
// what cannot be mounted goes to standard error. See node_exporter.jail.

import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as jail from 'node_exporter.jail';

const mods = deps.modules();
const log = (msg) => warn(`${msg}\n`);
const collectors = loader.load(mods.fs, loader.DIR, loader.import_module, log);
const res = jail.mounts(collectors, { uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH });

for (let p in res.problems)
	log(p);

print(join('\n', res.mounts), '\n');
