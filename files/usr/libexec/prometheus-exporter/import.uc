#!/usr/bin/ucode
'use strict';

import { cursor } from 'uci';
import * as deps from 'prometheus.exporter.deps';
import * as app from 'prometheus.exporter.app';
import { run, move_hash } from 'prometheus.exporter.migrate';

const uci = cursor();
const lines = [ ...move_hash(uci).lines ];

function installed() {
	let metas = {};

	for (let c in app.load(deps.modules(), null, (level, msg) => push(lines, msg)))
		metas[c.id] = c.meta;

	return metas;
}

push(lines, ...run(uci, installed).lines);

for (let line in lines)
	print(line, '\n');
