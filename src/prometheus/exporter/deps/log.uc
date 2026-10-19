/**
 * The exporter's log: syslog, at each message's priority.
 *
 * @module prometheus_exporter_deps_log
 */

'use strict';

import { openlog, syslog, LOG_PID, LOG_DAEMON, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO } from 'log';

/**
 * log(level, msg): the exporter's log; `level` one of LEVELS' names.
 *
 * @typedef {(level: string, msg: string) => void} Log
 */

/**
 * The levels the exporter logs at, as syslog's priorities.
 *
 * @type {Object<string, string>}
 */
export const LEVELS = { err: 'LOG_ERR', warning: 'LOG_WARNING', notice: 'LOG_NOTICE', info: 'LOG_INFO' };

/**
 * The lines a collector's log capability takes in one run.
 *
 * @type {int}
 */
export const LOG_LINES = 10;

/**
 * The bytes of a collector's line the log takes; the rest is cut, and '...' says so.
 *
 * @type {int}
 */
export const LOG_BYTES = 512;

/**
 * log(level, msg) over a syslog module, as the daemon `ident`, at each level's priority.
 *
 * @param {module:log} mod the log module, or an object of its openlog, syslog and LOG_* (a test's).
 * @param {string} ident the name syslog gives the daemon.
 * @returns {Log} the log; it dies on a level LEVELS does not name.
 */
export function syslog_channel(mod, ident) {
	mod.openlog(ident, mod.LOG_PID, mod.LOG_DAEMON);

	return function(level, msg) {
		if (!(level in keys(LEVELS)))
			die(`unknown log level '${level}'`);

		mod.syslog(mod[LEVELS[level]], '%s', msg);
	};
};

/**
 * The exporter's log on the real system: syslog_channel over the log module.
 *
 * @param {string} ident the name syslog gives the daemon.
 * @returns {Log} the log.
 */
export function system_log(ident) {
	return syslog_channel({ openlog, syslog, LOG_PID, LOG_DAEMON, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO }, ident);
};
