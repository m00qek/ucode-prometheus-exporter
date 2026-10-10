#!/usr/bin/ucode
'use strict';

import { cursor } from 'uci';
import { run, move_hash } from 'prometheus_exporter.migrate';

const uci = cursor();

for (let line in [ ...move_hash(uci).lines, ...run(uci).lines ])
	print(line, '\n');
