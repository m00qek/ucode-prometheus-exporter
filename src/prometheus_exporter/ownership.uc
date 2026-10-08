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

const SCRAPE_LENGTH = length(SCRAPE_PREFIX);
const EXPORTER_LENGTH = length(EXPORTER_PREFIX);

// loader.OWN as a set: a scrape asks it of every run.
const OWN = {};

for (let id in loader.OWN)
	OWN[id] = true;

// Why the collector named `me` may not write family `name`, which `owners`
// ({ family: collector name }) says who wrote first, or null when it may.
// `exporter`: whether it describes the exporter.
function family_problem(me, name, owners, exporter) {
	let owner = owners[name];

	if (substr(name, 0, SCRAPE_LENGTH) == SCRAPE_PREFIX)
		return `${name} belongs to the scrape itself`;
	if (!exporter && substr(name, 0, EXPORTER_LENGTH) == EXPORTER_PREFIX)
		return `${name} belongs to the exporter itself`;
	if (owner != null && owner != me)
		return `${name} belongs to collector ${owner}`;

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
	let first = filter(runs, (r) => OWN[r.id]);

	for (let r in [ ...first, ...filter(runs, (r) => !OWN[r.id]) ]) {
		let me = r.name;
		let exporter = 'exporter' in by_id[r.id].meta.needs;
		let why = null;
		let i = 0;

		// Each family is taken as it is checked, a scrape's hundreds in one
		// pass: a run that may not write one gives back what it took.
		for (let f in r.families) {
			let name = f.name;
			let owner = owners[name];

			if (owner == me || (owner == null && substr(name, 0, SCRAPE_LENGTH) != SCRAPE_PREFIX &&
			    (exporter || substr(name, 0, EXPORTER_LENGTH) != EXPORTER_PREFIX))) {
				owners[name] = me;
				i++;
				continue;
			}

			why = family_problem(me, name, owners, exporter);
			break;
		}

		if (why) {
			for (let j = 0; j < i; j++)
				if (owners[r.families[j].name] == me)
					delete owners[r.families[j].name];

			r.result = Result.err(errors.FAMILY_CONFLICT, why);
			r.families = [];
			r.text = '';
			r.samples = 0;
			env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
		}
	}

	return runs;
};
