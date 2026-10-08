/**
 * Whose each family of a scrape's reply is: the first collector's that writes
 * it, the exporter's own collectors (loader.OWN) before the others; and the
 * families the core keeps for itself, which no collector may write
 * (prometheus_exporter.scrape).
 *
 * @module prometheus_exporter_ownership
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as loader from 'prometheus_exporter.loader';

// The prefixes of the families the core writes: node_exporter's
// node_scrape_collector_* of every collector, and the exporter's own, which
// only a collector that describes the exporter (exporter in meta.needs) may
// write too.

/**
 * node_exporter's node_scrape_collector_*, of every collector.
 *
 * @type {string}
 */
export const SCRAPE_PREFIX = 'node_scrape_collector_';

/**
 * The exporter's own, ucode_prometheus_exporter_*.
 *
 * @type {string}
 */
export const EXPORTER_PREFIX = 'ucode_prometheus_exporter_';

function prefixed(name, prefix) {
	return substr(name, 0, length(prefix)) == prefix;
}

// Why collector `c` may not write family `name`, which `owners` ({ family:
// collector name }) says who wrote first, or null when it may.
function family_problem(c, name, owners) {
	if (prefixed(name, SCRAPE_PREFIX))
		return `${name} belongs to the scrape itself`;
	if (prefixed(name, EXPORTER_PREFIX) && !('exporter' in c.meta.needs))
		return `${name} belongs to the exporter itself`;
	if (owners[name] != null && owners[name] != c.meta.name)
		return `${name} belongs to collector ${owners[name]}`;

	return null;
}

/**
 * Each family to the first collector of `runs` (scrape.run_one's, in the
 * order of the reply, `by_id` their collectors) that writes it: a run that
 * writes a family another wrote first, or one the core keeps for itself,
 * fails with FAMILY_CONFLICT, logged at warning, and none of its samples are
 * served. The exporter's own collectors (loader.OWN) come first, then the
 * others; each in the order of the reply, not the order they ran in, so the
 * same collector wins every scrape, and one of another package never takes
 * a family of the exporter's own. A family a collector writes is its own,
 * and the reply has each once.
 *
 * @param {ScrapeEnv} env the scrape's env, whose log it logs at.
 * @param {Run[]} runs the runs, in the order of the reply; a run that may
 *   not write a family is changed to fail.
 * @param {Object<string, Collector>} by_id their collectors, by id.
 * @returns {Run[]} `runs`.
 */
export function own(env, runs, by_id) {
	let owners = {};
	let first = filter(runs, (r) => r.id in loader.OWN);

	for (let r in [ ...first, ...filter(runs, (r) => !(r.id in loader.OWN)) ]) {
		let c = by_id[r.id];
		let why = null;

		for (let f in r.families) {
			why = family_problem(c, f.name, owners);
			if (why)
				break;
		}

		if (why) {
			r.result = Result.err(errors.FAMILY_CONFLICT, why);
			r.families = [];
			r.text = '';
			r.samples = 0;
			env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
			continue;
		}

		for (let f in r.families)
			owners[f.name] ??= r.name;
	}

	return runs;
};
