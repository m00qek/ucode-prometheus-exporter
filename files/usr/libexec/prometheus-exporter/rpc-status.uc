#!/usr/bin/ucode
'use strict';

import * as rpc from 'prometheus_exporter.rpc';
import { probe } from 'prometheus_exporter.probe';
import { import_module } from 'prometheus_exporter.loader';

const sys = rpc.system({ probe: (ids) => probe(ids, import_module) });

printf('%J\n', rpc.status(sys));
sys.ubus.close();
