#!/usr/bin/ucode
'use strict';

import { probe } from 'prometheus_exporter.probe';
import { import_module } from 'prometheus_exporter.loader';

if (!length(ARGV) || length(filter(ARGV, (id) => !match(id, /^[a-z0-9_]+$/)))) {
	warn('usage: probe.uc MODULE...\n');
	exit(2);
}

printf('%J\n', probe(ARGV, import_module));
