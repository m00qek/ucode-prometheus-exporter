#!/usr/bin/ucode
'use strict';

// Takes over the settings of the feed's prometheus-node-exporter-ucode or -lua
// into an unchanged /etc/config/prometheus-exporter, for the package's
// uci-defaults script; prints what it did. See prometheus_exporter.migrate.

import { cursor } from 'uci';
import { run } from 'prometheus_exporter.migrate';

const res = run(cursor());

for (let line in res.lines)
	print(line, '\n');
