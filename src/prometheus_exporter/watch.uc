/**
 * Waits for paths the jail left out, and reloads the service once they are there.
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

/** The procd trigger that reloads the service. */
export const EVENT = `${config.NAME}.path`;

/** How often it looks, in ms, while nothing is there. */
export const INTERVAL_MS = 5000;

/** How long it waits after it asked for a reload, in ms. */
export const QUIET_MS = 60000;

/**
 * Looks `rounds` times, for ever without, and says what it did each round.
 *
 * @param {WatchSys} sys
 * @param {string[]} paths
 * @param {?int} rounds
 * @returns {{ found: string[], reloaded: boolean }[]}
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
