#!/usr/bin/ucode
'use strict';

import * as rpc from 'prometheus.exporter.rpc';
import { probe } from 'prometheus.exporter.probe';
import { import_module } from 'prometheus.exporter.loader';

const sys = rpc.system({ ledger: true, probe: (ids) => probe(ids, import_module) });

printf('%J\n', rpc.status(sys));
sys.ubus.close();
