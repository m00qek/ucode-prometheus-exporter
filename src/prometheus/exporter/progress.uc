/**
 * What a scrape makes of the progress files of the instance's scrape processes that died.
 *
 * @module prometheus_exporter_progress
 */

'use strict';

import * as ledger from 'prometheus.exporter.ledger';
import { SIZE_MAX } from 'prometheus.exporter.state';

/**
 * Logs what changed of the breakers: a trip at warning, a close at notice.
 *
 * @param {ScrapeEnv} env the scrape's env, whose log it logs at.
 * @param {BreakerEvent[]} events what changed.
 */
export function log_breakers(env, events) {
	for (let e in events) {
		if (e.tripped)
			env.log('warning', `collector '${e.name}' quarantined for ${e.cooldown} scrape${e.cooldown == 1 ? '' : 's'}: ${e.why}`);
		else if (e.closed)
			env.log('notice', `collector '${e.name}' served again: its trial succeeded`);
	}
};

/**
 * The collectors running when a scrape process died fail COLLECTOR_KILLED; their children die.
 *
 * @param {ScrapeEnv} env the scrape's env: its log, and kill.
 * @param {State} state the instance's state.
 * @param {Collector[]} collectors the installed collectors.
 */
export function bury(env, state, collectors) {
	let dead = state.dead();

	if (!length(dead))
		return;

	let names = {};
	let events = [];
	let blamed = [];

	for (let c in collectors)
		names[c.id] = c.meta.name;

	state.update(ledger.NAME, function(text) {
		let l = ledger.parse(text);

		events = [];
		blamed = [];
		for (let d in dead) {
			if (!state.claim(d.file))
				continue;
			if (d.running == null || names[d.running] == null)
				continue;

			push(blamed, names[d.running]);
			if (d.child && env.kill)
				env.kill(d.child.pid);
			l = ledger.killed(l, d.running, names[d.running],
				'its scrape process died while it ran: out of memory, a crash, or killed', events);
		}

		return ledger.serialize(l, SIZE_MAX);
	});

	for (let name in blamed)
		env.log('warning', `collector '${name}' was running when a scrape process died`);
	log_breakers(env, events);
};
