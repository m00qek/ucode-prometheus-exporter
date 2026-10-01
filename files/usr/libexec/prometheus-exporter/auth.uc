#!/usr/bin/ucode
'use strict';

// Basic auth's file for /etc/init.d/prometheus-exporter: uhttpd's config file
// (-c) of the main section's auth_user and auth_password. Prints its path; or,
// when the main section sets no basic auth, removes it and prints nothing.
// Exits 1, saying why on standard error, when the main section is invalid or
// the file cannot be written. See prometheus_exporter.auth.

import * as fs from 'fs';
import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import * as auth from 'prometheus_exporter.auth';
import * as Result from 'prometheus_exporter.result';

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
