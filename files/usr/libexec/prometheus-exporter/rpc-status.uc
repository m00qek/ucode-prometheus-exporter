#!/usr/bin/ucode
'use strict';

// The reply of the ubus object's `status`, as one line of JSON. rpcd runs it in
// a process of its own: a scrape may call ubus objects that rpcd serves itself,
// which rpcd could not answer while it waited for the scrape. See
// prometheus_exporter.rpc.

import * as rpc from 'prometheus_exporter.rpc';

const sys = rpc.system();

printf('%J\n', rpc.status(sys));
sys.ubus.close();
