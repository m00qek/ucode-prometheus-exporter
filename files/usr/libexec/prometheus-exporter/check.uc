#!/usr/bin/ucode
'use strict';

import * as check from 'prometheus_exporter.check';

const config_only = (ARGV[0] == '--config');

if (length(ARGV) > 1 || (length(ARGV) == 1 && !config_only)) {
	warn('usage: check.uc [--config]\n');
	exit(2);
}

const res = check.run(check.system(), { config_only });

print(res.report, '\n');
exit(res.ok ? 0 : 1);
