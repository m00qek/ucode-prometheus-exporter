'use strict';

// Waits for paths the collectors read that were not there when the service
// started: the jail left them out, and a reload once they are there mounts
// them. The init script runs it as the service's `watch` instance with those
// paths, and reloads the service on EVENT, a procd trigger.
//
// It looks every INTERVAL_MS (a stat each, while something is missing). Once a
// path is there, it sends EVENT and waits QUIET_MS: the reload ends this
// instance, or starts it again with the paths still missing; when the reload
// cannot (an invalid config, which the log says), it asks again then.
//
// sys: { exists(path), sleep(ms), reload() -> whether procd took the event,
//        log(msg) }

import * as config from 'prometheus_exporter.config';

export const EVENT = `${config.NAME}.path`;
export const INTERVAL_MS = 5000;
export const QUIET_MS = 60000;

// Looks `rounds` times (for ever without), and says what it did each round:
// [ { found: [ path ], reloaded } ].
export function run(sys, paths, rounds) {
	let done = [];

	for (let i = 0; rounds == null || i < rounds; i++) {
		let found = filter(paths, (p) => sys.exists(p));

		if (!length(found)) {
			push(done, { found, reloaded: false });
			sys.sleep(INTERVAL_MS);
			continue;
		}

		sys.log(`${join(', ', found)} ${length(found) == 1 ? 'is' : 'are'} there now: reloading to mount ${length(found) == 1 ? 'it' : 'them'}`);

		let reloaded = sys.reload();

		if (!reloaded)
			sys.log(`cannot send procd ${EVENT}; trying again in ${QUIET_MS / 1000}s`);

		push(done, { found, reloaded });
		sys.sleep(QUIET_MS);
	}

	return done;
};
