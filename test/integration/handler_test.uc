'use strict';

// The uhttpd handler template, run as uhttpd-mod-ucode runs it: loaded once as a
// template, then handle_request(env) per request with `uhttpd` as a global.

import { describe, it, afterEach, assert, contains, mock } from 'utest';
import { DIR } from 'prometheus_exporter.loader';
import * as config from 'prometheus_exporter.config';
import * as auth from 'prometheus_exporter.auth';
import { inflate } from 'zlib';
import * as lockable from 'lib.lockable';

const HANDLER = 'files/usr/libexec/prometheus-exporter/handler.uc';

// The collectors as installed: their files listed in DIR, their modules found on
// the search path.
function install(files) {
	let fs = mock.global.patch('fs', { data: { [DIR + '/loadavg.uc']: '', ...files }, behavior: { open: lockable.open } });
	mock.global.patch('ubus', { strict: true, data: {} });
	mock.global.patch('uci', { strict: true, data: { [config.NAME]: {} } });
	return fs;
}

// The handler, loaded once as uhttpd does; each call of the result is a request.
function serve() {
	let sent = [];
	global.uhttpd = { send: (...parts) => push(sent, join('', parts)) };
	loadfile(HANDLER, { raw_mode: false })();

	let handle = global.handle_request;

	return function(query_string) {
		sent = [];
		global.uhttpd = { send: (...parts) => push(sent, join('', parts)) };
		handle({ QUERY_STRING: query_string, PATH_INFO: '/metrics' });
		return join('', sent);
	};
}

function answered(reply) {
	return map(filter(split(reply, '\n'), (l) => index(l, 'node_scrape_collector_success{') == 0),
		(l) => match(l, /collector="([^"]+)"/)[1]);
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

		assert.match('Status: 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nVary: Accept-Encoding', head[0]);
		assert.match(contains([ 'node_load1 0.01', 'node_scrape_collector_success{collector="loadavg"} 1' ]), split(head[1], '\n'));
	});

	// Installing or removing a collector package reloads the service, which
	// restarts uhttpd: a running handler keeps what it loaded.
	it('serves the collectors it loaded when it started, until it starts again', () => {
		let fs = install({ '/proc/loadavg': '0.01 0.02 0.03 1/1 1\n' });
		let request = serve();

		assert.match([ 'loadavg' ], answered(request('')));

		fs.writefile(DIR + '/time.uc', '');
		assert.match([ 'loadavg' ], answered(request('')), 'installed while running');

		let restarted = serve();
		assert.match([ 'loadavg', 'time' ], answered(restarted('')), 'installed, then restarted');

		fs.unlink(DIR + '/time.uc');
		assert.match([ 'loadavg', 'time' ], answered(restarted('')), 'removed while running');
		assert.match([ 'loadavg' ], answered(serve()('')), 'removed, then restarted');
	});

	// uhttpd-mod-ucode's env: Accept-Encoding among the headers, named in lower case.
	it('sends a gzip body with its headers when the scraper asks for it', () => {
		install({ '/proc/loadavg': '0.01 0.02 0.03 1/1 1\n' });

		let sent = [];
		global.uhttpd = { send: (...parts) => push(sent, ...parts) };
		loadfile(HANDLER, { raw_mode: false })();
		global.handle_request({ QUERY_STRING: 'collect[]=loadavg', headers: { 'accept-encoding': 'gzip' } });

		assert.match('Status: 200 OK\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\n' +
			'Vary: Accept-Encoding\r\nContent-Encoding: gzip\r\n\r\n', sent[0]);
		assert.match(contains([ 'node_load1 0.01' ]), split(inflate(sent[1]), '\n'));
	});

	it('answers 401 when basic auth\'s file is there and the request has no credentials', () => {
		install({ '/proc/loadavg': '0.01 0.02 0.03 1/1 1\n', [auth.FILE]: auth.conf('prom', '$1$$ysVNzQc4CTMkp5daOdZ.3/') });

		let sent = [];
		global.uhttpd = { send: (...parts) => push(sent, join('', parts)) };
		loadfile(HANDLER, { raw_mode: false })();
		global.handle_request({ QUERY_STRING: '', HTTPS: 'on', headers: {} });

		assert.match('Status: 401 Unauthorized\r\nContent-Type: text/plain; charset=utf-8\r\n' +
			'WWW-Authenticate: Basic realm="prometheus-exporter"\r\n\r\nUnauthorized.\n', sent[0]);
	});

	it('answers 400 for an unknown collector', () => {
		install({});
		assert.match("Status: 400 Bad Request\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nVary: Accept-Encoding\r\n\r\n" +
			"COLLECTOR_INVALID (unknown collector 'nope')\n", request('collect[]=nope'));
	});
});
