{%
'use strict';

// Based on the uhttpd handler of utils/prometheus-node-exporter-ucode/files/metrics.uc
// in OpenWrt's packages feed (Apache-2.0); see NOTICE.

// uhttpd's ucode handler for /metrics; see /etc/init.d/prometheus-exporter.
// uhttpd runs this once, then handle_request in a process of its own per request.

import { handler } from 'prometheus_exporter.app';
import { head } from 'prometheus_exporter.http';
import { system_log } from 'prometheus_exporter.deps';
import { NAME } from 'prometheus_exporter.config';

// To syslog, at each message's level: procd would log the handler's stderr at err.
const log = system_log(NAME);
const app = handler(log);

log('info', `serving ${length(app.collectors())} collectors` + (app.compress ? ', gzip when asked' : ''));

global.handle_request = function(env) {
	const reply = app.handle(env);

	uhttpd.send(head(reply), reply.body);
};
-%}
