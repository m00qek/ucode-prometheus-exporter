#!/usr/bin/ucode
'use strict';

import * as fs from 'fs';
import * as deps from 'prometheus.exporter.deps';
import * as config from 'prometheus.exporter.config';
import * as auth from 'prometheus.exporter.auth';
import * as Result from 'prometheus.exporter.result';

if (length(ARGV)) {
	warn('usage: auth.uc\n');
	exit(2);
}

let res = config.auth(deps.modules().uci.cursor());

if (res.ok)
	res = auth.write_conf(fs, res.data);

if (!res.ok) {
	warn(`${Result.describe(res)}\n`);
	exit(1);
}

if (res.data != null)
	print(res.data, '\n');
