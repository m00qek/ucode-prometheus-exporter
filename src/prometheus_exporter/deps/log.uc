/**
 * The exporter's log: syslog, at each message's priority. A collector's log
 * capability writes there, through its scrape's session.
 *
 * @module prometheus_exporter_deps_log
 */

'use strict';

import { openlog, syslog, LOG_PID, LOG_DAEMON, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO } from 'log';

/**
 * log(level, msg): the exporter's log, as the loader, the scrapes and the
 * collectors call it; `level` one of LEVELS' names (err, warning, notice,
 * info).
 *
 * @typedef {(level: string, msg: string) => void} Log
 */

/**
 * The levels the exporter logs at, as syslog's priorities. err: what stops it
 * doing its job (an invalid configuration, a collector that does not load);
 * warning: what it does without (a collector that fails, which the scrape
 * answers without); notice and info: what it says of itself (how many
 * collectors it serves, a directory it made).
 *
 * @type {Object<string, string>}
 */
export const LEVELS = { err: 'LOG_ERR', warning: 'LOG_WARNING', notice: 'LOG_NOTICE', info: 'LOG_INFO' };

/**
 * log(level, msg) over a syslog module (the `log` module's openlog, syslog and
 * LOG_*): each message to syslog as the daemon `ident`, with its pid, at its
 * level's priority. procd's log of a service's stderr has one priority for
 * everything, err, which is why the exporter does not write there.
 *
 * @param {module:log} mod the log module, or an object of its openlog,
 *   syslog and LOG_* constants (a test's).
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
