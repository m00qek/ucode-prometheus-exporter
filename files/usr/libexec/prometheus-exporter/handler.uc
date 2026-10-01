{%
'use strict';

// Based on the uhttpd handler of utils/prometheus-node-exporter-ucode/files/metrics.uc
// in OpenWrt's packages feed (Apache-2.0); see NOTICE.

// uhttpd's ucode handler for /metrics; see /etc/init.d/prometheus-exporter.

import { create } from 'prometheus_exporter.app';
import { system_log } from 'prometheus_exporter.deps';
import { NAME } from 'prometheus_exporter.config';

// To syslog, at each message's level: procd would log the handler's stderr at err.
const log = system_log(NAME);
const app = create(log);

log('info', `serving ${length(app.collectors())} collectors`);

global.handle_request = function(env) {
	const res = app.scrape(env.QUERY_STRING);

	uhttpd.send(`Status: ${res.status}\r\nContent-Type: ${res.content_type}\r\n\r\n`, res.body);
};
-%}
