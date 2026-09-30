'use strict';

// The uhttpd handler template, run as uhttpd-mod-ucode runs it: loaded once as a
// template, then handle_request(env) per request with `uhttpd` as a global.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { DIR } from 'node_exporter.loader';
import * as config from 'node_exporter.config';

const HANDLER = 'files/usr/libexec/prometheus-node-exporter-ucode/handler.uc';

// The collectors as installed: their files listed in DIR, their modules found on
// the search path.
function install(files) {
	mock.global.patch('fs', { data: { [DIR + '/loadavg.uc']: '', ...files } });
	mock.global.patch('ubus', { strict: true, data: {} });
	mock.global.patch('uci', { strict: true, data: { [config.PACKAGE]: {} } });
}

function request(query_string) {
	let sent = [];
	global.uhttpd = { send: (...parts) => push(sent, join('', parts)) };

	loadfile(HANDLER, { raw_mode: false })();
	global.handle_request({ QUERY_STRING: query_string, PATH_INFO: '/metrics' });

	return join('', sent);
}

describe('handler', () => {
	afterEach(() => {
		delete global.uhttpd;
		delete global.handle_request;
		mock.global.unpatch('fs');
		mock.global.unpatch('ubus');
		mock.global.unpatch('uci');
	});

	it('answers a scrape with a status, a content type and the metrics', () => {
		install({ '/proc/loadavg': '0.01 0.02 0.03 1/1 1\n' });

		let reply = request('collect[]=loadavg');
		let head = split(reply, '\r\n\r\n', 2);

		assert.match('Status: 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8', head[0]);
		assert.match(contains([ 'node_load1 0.01', 'node_scrape_collector_success{collector="loadavg"} 1' ]), split(head[1], '\n'));
	});

	it('answers 400 for an unknown collector', () => {
		install({});
		assert.match("Status: 400 Bad Request\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n" +
			"COLLECTOR_INVALID (unknown collector 'nope')\n", request('collect[]=nope'));
	});
});
