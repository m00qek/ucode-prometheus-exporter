/**
 * What a scrape makes of the progress files of the instance's scrape
 * processes that died (prometheus_exporter.state's dead): the collector each
 * was running is reckoned killed, and the child it ran in is killed; and the
 * breakers that tripped or closed, logged, of those and of each scrape
 * (prometheus_exporter.scrape).
 *
 * @module prometheus_exporter_progress
 */

'use strict';

import * as ledger from 'prometheus_exporter.ledger';

/**
 * What changed of the breakers (ledger.record's events), logged: a breaker
 * that tripped at warning, one that closed at notice.
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
 * The collectors that were running when a scrape process of the instance
 * died (prometheus_exporter.state's dead): each fails with COLLECTOR_KILLED,
 * which trips its breaker, counted and logged at warning. A process that
 * died once its collectors were done costs none of them. Each dead process
 * is reckoned once, by the scrape that claims its progress file, under the
 * state's lock. The child process its collector ran in, which nothing stops
 * once the scrape that held its timer is gone, is killed (env.kill).
 *
 * @param {ScrapeEnv} env the scrape's env: its log, and kill.
 * @param {State} st the instance's state.
 * @param {Collector[]} collectors the installed collectors.
 */
export function bury(env, st, collectors) {
	let dead = st.dead();

	if (!length(dead))
		return;

	let names = {};
	let events = [];
	let blamed = [];

	for (let c in collectors)
		names[c.id] = c.meta.name;

	st.update(ledger.NAME, function(text) {
		let l = ledger.parse(text);

		events = [];
		blamed = [];
		for (let d in dead) {
			if (!st.claim(d.file))
				continue;
			if (d.running == null || names[d.running] == null)
				continue;

			push(blamed, names[d.running]);
			if (d.child && env.kill)
				env.kill(d.child.pid);
			l = ledger.killed(l, d.running, names[d.running],
				'its scrape process died while it ran: out of memory, a crash, or killed', events);
		}

		return ledger.serialize(l);
	});

	for (let name in blamed)
		env.log('warning', `collector '${name}' was running when a scrape process died`);
	log_breakers(env, events);
};
