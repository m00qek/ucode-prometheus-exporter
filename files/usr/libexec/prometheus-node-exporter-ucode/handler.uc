{%
'use strict';

// Based on the uhttpd handler of utils/prometheus-node-exporter-ucode/files/metrics.uc
// in OpenWrt's packages feed (Apache-2.0); see NOTICE.

// uhttpd's ucode handler for /metrics; see /etc/init.d/prometheus-node-exporter-ucode.

import { create } from 'node_exporter.app';

const app = create((msg) => warn(`prometheus-node-exporter-ucode: ${msg}\n`));

warn(`prometheus-node-exporter-ucode: serving ${length(app.collectors())} collectors\n`);

global.handle_request = function(env) {
	const res = app.scrape(env.QUERY_STRING);

	uhttpd.send(`Status: ${res.status}\r\nContent-Type: ${res.content_type}\r\n\r\n`, res.body);
};
-%}
