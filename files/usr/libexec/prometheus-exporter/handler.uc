{%
'use strict';

import { handler } from 'prometheus.exporter.app';
import { head } from 'prometheus.exporter.http';
import { system_log } from 'prometheus.exporter.deps';
import { NAME } from 'prometheus.exporter.config';

const log = system_log(NAME);
const app = handler(log);

log('info', `serving ${length(app.collectors())} collectors` +
	(app.auth ? ', with basic auth' : '') + (app.compress ? ', gzip when asked' : ''));

global.handle_request = function(env) {
	const reply = app.handle(env);

	uhttpd.send(head(reply), reply.body);
};
-%}
