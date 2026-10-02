#!/usr/bin/ucode
'use strict';

// The reply of the ubus object's `status`, as one line of JSON. rpcd runs it in
// a process of its own: a scrape may call ubus objects that rpcd serves itself,
// which rpcd could not answer while it waited for the scrape. It loads the
// collectors and runs them as the service does, each in a process of its own,
// stopped at its limit and by the scrape's deadline, so it ends within the
// main section's scrape_timeout whatever a collector does. See
// prometheus_exporter.rpc.

import * as rpc from 'prometheus_exporter.rpc';
import { probe } from 'prometheus_exporter.probe';
import { import_module } from 'prometheus_exporter.loader';

const sys = rpc.system({ probe: (ids) => probe(ids, import_module) });

printf('%J\n', rpc.status(sys));
sys.ubus.close();
