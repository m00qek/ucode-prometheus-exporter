#!/usr/bin/ucode
'use strict';

// The service's `watch` instance, which the init script runs while a path its
// collectors read is not there (they are the arguments): unbound's socket
// directory, say, which unbound makes when it starts, after the exporter at
// boot. Once one of them is there, it asks procd for the trigger that reloads
// the service, which then mounts it; the reload ends this instance, or starts
// it again for the paths still missing. See prometheus_exporter.watch.

import { stat } from 'fs';
import { connect } from 'ubus';
import * as watch from 'prometheus_exporter.watch';

if (!length(ARGV)) {
	warn('usage: watch.uc PATH...\n');
	exit(2);
}

watch.run({
	exists: (p) => stat(p) != null,
	sleep: (ms) => sleep(ms),
	reload: function() {
		let ubus = connect();

		if (!ubus)
			return false;

		ubus.call('service', 'event', { type: watch.EVENT, data: {} });

		let ok = ubus.error() == null;

		ubus.disconnect();
		return ok;
	},
	log: (msg) => warn(`${msg}\n`),
}, ARGV);
