'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as deps_log from 'prometheus_exporter.deps.log';

describe('deps.log.syslog_channel', () => {
	// The log module's openlog and syslog, recorded; its LOG_* as on OpenWrt.
	function fake_log() {
		let out = { opened: null, lines: [] };

		out.mod = {
			LOG_PID: 1, LOG_DAEMON: 24, LOG_ERR: 3, LOG_WARNING: 4, LOG_NOTICE: 5, LOG_INFO: 6,
			openlog: (ident, options, facility) => { out.opened = [ ident, options, facility ]; return true; },
			syslog: (priority, format, ...args) => { push(out.lines, [ priority, format, ...args ]); return true; },
		};

		return out;
	}

	it('opens the daemon facility as the service, with its pid', () => {
		let log = fake_log();

		deps_log.syslog_channel(log.mod, 'prometheus-exporter');
		assert.match([ 'prometheus-exporter', 1, 24 ], log.opened);
	});

	it('logs each level at its syslog priority', () => {
		let log = fake_log();
		let emit = deps_log.syslog_channel(log.mod, 'prometheus-exporter');

		for (let level in [ 'err', 'warning', 'notice', 'info' ])
			emit(level, level);

		assert.match([ [ 3, '%s', 'err' ], [ 4, '%s', 'warning' ], [ 5, '%s', 'notice' ], [ 6, '%s', 'info' ] ], log.lines);
		assert.match([ 'err', 'warning', 'notice', 'info' ], keys(deps_log.LEVELS));
	});

	it('refuses a level it does not know', () => {
		let emit = deps_log.syslog_channel(fake_log().mod, 'prometheus-exporter');

		for (let level in [ 'debug', 'warn', 'error', null ]) {
			let failed = false;
			try { emit(level, 'x'); } catch (e) { failed = index(e.message, 'unknown log level') >= 0; }
			assert.match(true, failed, `${level}`);
		}
	});

	prop('passes any message on as it is, never as a format',
		gen.tuple(gen.elements('err', 'warning', 'notice', 'info'), gen.ascii({ min_len: 0, max_len: 24 })), (t) => {
			let log = fake_log();

			deps_log.syslog_channel(log.mod, 'prometheus-exporter')(t[0], t[1]);
			assert.match([ [ log.mod[deps_log.LEVELS[t[0]]], '%s', t[1] ] ], log.lines);
		});

	it('takes the real log module', () => {
		assert.match('function', type(deps_log.system_log('prometheus-exporter-test')));
	});
});
