'use strict';

// The collector API: exactly the names it lists, each the core's own.

import { describe, it, assert } from 'utest';
import * as api from 'prometheus_exporter.api';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as services from 'prometheus_exporter.services';
import * as proc from 'prometheus_exporter.proc';
import * as exposition from 'prometheus_exporter.exposition';

describe('prometheus_exporter.api', () => {
	it('exports Result, errors, services, proc and exposition, and nothing else', () => {
		assert.match([ 'Result', 'errors', 'exposition', 'proc', 'services' ], sort(keys(api)));
	});

	it('gives Result\'s functions', () => {
		assert.match([ 'describe', 'err', 'is', 'is_none', 'none', 'ok' ], sort(keys(api.Result)));
		for (let k in keys(api.Result))
			assert.match(true, api.Result[k] === Result[k], k);
	});

	it('gives the codes a collector fails with, and those of its capabilities, not the core\'s own', () => {
		assert.match([
			'COMMAND_FAILED', 'COMMAND_NOT_ALLOWED', 'COMMAND_TIMEOUT', 'CONFIG_INVALID', 'EXPOSITION_INVALID',
			'NL80211_FAILED', 'RTNL_FAILED', 'SCRAPE_DEADLINE', 'SOCKET_FAILED', 'SOURCE_INVALID', 'SOURCE_UNREADABLE',
			'UBUS_CALL_FAILED', 'UBUS_CONNECT_FAILED',
		], sort(keys(api.errors)));
		for (let k, v in api.errors)
			assert.match(errors[k], v, k);
	});

	it('gives services\' and proc\'s functions and constants', () => {
		assert.match([ 'DISABLED', 'ENABLED', 'NOT_FOUND', 'NOT_INSTALLED', 'idle', 'object_missing', 'state', 'unless_disabled' ],
			sort(keys(api.services)));
		assert.match([ 'AT_CLKTCK', 'AT_PAGESZ', 'auxv', 'each_line', 'fields', 'first_line', 'lines' ], sort(keys(api.proc)));

		for (let k in keys(api.services))
			assert.match(true, api.services[k] === services[k], k);
		for (let k in keys(api.proc))
			assert.match(true, api.proc[k] === proc[k], k);
	});

	it('gives the exposition format\'s parse, format_value and sanitize, loaded once called', () => {
		assert.match([ 'format_value', 'parse', 'sanitize' ], sort(keys(api.exposition)));
		assert.match([ exposition.format_value(1.5), exposition.sanitize('a-b.c') ],
			[ api.exposition.format_value(1.5), api.exposition.sanitize('a-b.c') ]);

		let text = '# TYPE x gauge\nx{a="1"} 2\n';
		let res = api.exposition.parse(text);

		assert.match(true, Result.is(res) && res.ok);
		assert.match(exposition.parse(text).data, res.data);
		res = api.exposition.parse('x{');
		assert.match([ false, 'EXPOSITION_INVALID' ], [ res.ok, res.error ]);
	});
});
