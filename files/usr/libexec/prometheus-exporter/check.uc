#!/usr/bin/ucode
'use strict';

// `service prometheus-exporter check`, and, with --config, the check the
// init script runs before start and reload: the configuration, the installed
// collectors and a scrape of them, or with --config the configuration alone
// (prometheus_exporter.check). Prints the report; exits 1 when the
// configuration is not valid. The base package's, so the service needs no
// command line: the command line's check (ucode-prometheus-exporter-cli)
// runs the same.

import * as check from 'prometheus_exporter.check';

const config_only = (ARGV[0] == '--config');

if (length(ARGV) > 1 || (length(ARGV) == 1 && !config_only)) {
	warn('usage: check.uc [--config]\n');
	exit(2);
}

const res = check.run(check.system(), { config_only });

print(res.report, '\n');
exit(res.ok ? 0 : 1);
