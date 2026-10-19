/**
 * Whose each family of a scrape's reply is, and the families the core keeps for itself.
 *
 * @module prometheus_exporter_ownership
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';

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

function family_problem(me, name, owners) {
	let owner = owners[name];

	if (substr(name, 0, SCRAPE_LENGTH) == SCRAPE_PREFIX)
		return `${name} belongs to the scrape itself`;
	if (substr(name, 0, EXPORTER_LENGTH) == EXPORTER_PREFIX)
		return `${name} belongs to the exporter itself`;
	if (owner != null && owner != me)
		return `${name} belongs to collector ${owner}`;

	return null;
}

function clear(runs) {
	let texts = [];
	let n = 0;

	for (let r in runs) {
		let names = r.families;

		if (!length(names))
			continue;

		let text = '\n' + join('\n', names);

		if (index(text, `\n${SCRAPE_PREFIX}`) >= 0 || index(text, `\n${EXPORTER_PREFIX}`) >= 0)
			return false;

		push(texts, text);
		n += length(names);
	}

	return !n || length(uniq(split(substr(join('', texts), 1), '\n'))) == n;
}

/**
 * Each family to the first collector of `runs` that writes it; any other fails FAMILY_CONFLICT.
 *
 * @param {ScrapeEnv} env the scrape's env, whose log it logs at.
 * @param {Run[]} runs the runs, in the reply's order; one that may not write a family fails.
 * @param {Object<string, Collector>} by_id their collectors, by id.
 * @returns {Run[]} `runs`.
 */
export function own(env, runs, by_id) {
	if (clear(runs))
		return runs;

	let owners = {};
	let first = filter(runs, (r) => by_id[r.id].own);

	for (let r in [ ...first, ...filter(runs, (r) => !by_id[r.id].own) ]) {
		let me = r.name;
		let why = null;
		let i = 0;

		for (let name in r.families) {
			let owner = owners[name];

			if (owner == me || (owner == null && substr(name, 0, SCRAPE_LENGTH) != SCRAPE_PREFIX &&
			    substr(name, 0, EXPORTER_LENGTH) != EXPORTER_PREFIX)) {
				owners[name] = me;
				i++;
				continue;
			}

			why = family_problem(me, name, owners);
			break;
		}

		if (why) {
			for (let j = 0; j < i; j++)
				if (owners[r.families[j]] == me)
					delete owners[r.families[j]];

			r.result = Result.err(errors.FAMILY_CONFLICT, why);
			r.families = [];
			r.text = '';
			r.samples = 0;
			env.log('warning', `collector '${r.name}': ${Result.describe(r.result)}`);
		}
	}

	return runs;
};
