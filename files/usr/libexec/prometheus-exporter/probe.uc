#!/usr/bin/ucode
'use strict';

// Loads each collector module named in its arguments in a process of its own,
// stopping one that does not load in time (prometheus_exporter.probe), and
// prints what it found as one line of JSON: { <id>: { ok, error,
// hung, seconds } }. rpcd's plugin runs it rather than load a module it has
// not seen load (prometheus_exporter.rpc's cached_probe).

import { probe } from 'prometheus_exporter.probe';
import { import_module } from 'prometheus_exporter.loader';

if (!length(ARGV) || length(filter(ARGV, (id) => !match(id, /^[a-z0-9_]+$/)))) {
	warn('usage: probe.uc MODULE...\n');
	exit(2);
}

printf('%J\n', probe(ARGV, import_module));
