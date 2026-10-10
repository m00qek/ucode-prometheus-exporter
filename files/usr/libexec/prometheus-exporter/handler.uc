{%
'use strict';

import { handler } from 'prometheus_exporter.app';
import { head } from 'prometheus_exporter.http';
import { system_log } from 'prometheus_exporter.deps';
import { NAME } from 'prometheus_exporter.config';

const log = system_log(NAME);
const app = handler(log);

log('info', `serving ${length(app.collectors())} collectors` +
	(app.auth ? ', with basic auth' : '') + (app.compress ? ', gzip when asked' : ''));

global.handle_request = function(env) {
	const reply = app.handle(env);

	uhttpd.send(head(reply), reply.body);
};
-%}
