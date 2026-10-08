#!/usr/bin/ucode
'use strict';

// Takes over the settings of the feed's prometheus-node-exporter-ucode or -lua
// into an unchanged /etc/config/prometheus-exporter, and moves basic auth's hash
// out of it into /etc/config/prometheus-exporter-auth, for the package's
// uci-defaults script; prints what it did. See prometheus_exporter.migrate.

import { cursor } from 'uci';
import { run, move_hash } from 'prometheus_exporter.migrate';

const uci = cursor();

for (let line in [ ...move_hash(uci).lines, ...run(uci).lines ])
	print(line, '\n');
