/**
 * Waits for paths the collectors read that were not there when the service
 * started: the jail left them out, and a reload once they are there mounts
 * them. The init script runs it as the service's `watch` instance with those
 * paths, and reloads the service on EVENT, a procd trigger.
 *
 * It looks every INTERVAL_MS (a stat each, while something is missing). Once a
 * path is there, it sends EVENT and waits QUIET_MS: the reload ends this
 * instance, or starts it again with the paths still missing; when the reload
 * cannot (an invalid config, which the log says), it asks again then.
 *
 * sys: { exists(path), sleep(ms), reload() -> whether procd took the event,
 *        log(level, msg) }
 *
 * @module prometheus_exporter_watch
 */

'use strict';

import * as config from 'prometheus_exporter.config';

/**
 * What the watcher takes of the system, as the module's top comment says.
 *
 * @typedef {{
 *   exists: function(string): boolean,
 *   sleep: function(int): void,
 *   reload: function(): boolean,
 *   log: Log
 * }} WatchSys
 */

/**
 * The procd trigger that reloads the service.
 *
 * @type {string}
 */
export const EVENT = `${config.NAME}.path`;

/**
 * How often it looks, in ms, while nothing is there.
 *
 * @type {int}
 */
export const INTERVAL_MS = 5000;

/**
 * How long it waits after it asked for a reload, in ms.
 *
 * @type {int}
 */
export const QUIET_MS = 60000;

/**
 * Looks `rounds` times (for ever without), and says what it did each round:
 * [ { found: [ path ], reloaded } ].
 *
 * @param {WatchSys} sys the system.
 * @param {string[]} paths the paths it waits for.
 * @param {?int} rounds how many times it looks; null for ever.
 * @returns {{ found: string[], reloaded: boolean }[]} what it did, each
 *   round.
 */
export function run(sys, paths, rounds) {
	let done = [];

	for (let i = 0; rounds == null || i < rounds; i++) {
		let found = filter(paths, (p) => sys.exists(p));

		if (!length(found)) {
			push(done, { found, reloaded: false });
			sys.sleep(INTERVAL_MS);
			continue;
		}

		sys.log('info', `${join(', ', found)} ${length(found) == 1 ? 'is' : 'are'} there now: reloading to mount ${length(found) == 1 ? 'it' : 'them'}`);

		let reloaded = sys.reload();

		if (!reloaded)
			sys.log('warning', `cannot send procd ${EVENT}; trying again in ${QUIET_MS / 1000}s`);

		push(done, { found, reloaded });
		sys.sleep(QUIET_MS);
	}

	return done;
};
