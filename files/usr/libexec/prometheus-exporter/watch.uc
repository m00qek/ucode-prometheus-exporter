#!/usr/bin/ucode
'use strict';

import { stat } from 'fs';
import { connect } from 'ubus';
import * as watch from 'prometheus_exporter.watch';
import { system_log } from 'prometheus_exporter.deps';
import { NAME } from 'prometheus_exporter.config';

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
	log: system_log(NAME),
}, ARGV);
