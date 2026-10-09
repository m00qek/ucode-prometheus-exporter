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

// Whether no family of `runs` needs a look: none is the core's, and none is
// written by two runs. A run's names are each once, as a recorder merges a
// family declared again, so a name twice among them all is two runs'; a
// name of the core's is found among all of a run's at once, after a
// newline, as no name holds one; and the names are counted again once
// uniq() has left each once, all of it done by ucode's builtins.
function clear(runs, by_id) {
	let texts = [];
	let n = 0;

	for (let r in runs) {
		let names = r.families;

		if (!length(names))
			continue;

		let text = '\n' + join('\n', names);

		if (index(text, `\n${SCRAPE_PREFIX}`) >= 0)
			return false;
		if (index(text, `\n${EXPORTER_PREFIX}`) >= 0 && !('exporter' in by_id[r.id].meta.needs))
			return false;

		push(texts, text);
		n += length(names);
	}

	return !n || length(uniq(split(substr(join('', texts), 1), '\n'))) == n;
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
 * A scrape's runs nearly always write each family once, and none of the
 * core's: that is checked first, of all the families at once, and only
 * runs that do not pass are looked at a family at a time.
 *
 * @param {ScrapeEnv} env the scrape's env, whose log it logs at.
 * @param {Run[]} runs the runs, in the order of the reply, their families'
 *   names; a run that may not write a family is changed to fail.
 * @param {Object<string, Collector>} by_id their collectors, by id.
 * @returns {Run[]} `runs`.
 */
export function own(env, runs, by_id) {
	if (clear(runs, by_id))
		return runs;

	let owners = {};
	let first = filter(runs, (r) => OWN[r.id]);

	for (let r in [ ...first, ...filter(runs, (r) => !OWN[r.id]) ]) {
		let me = r.name;
		let exporter = 'exporter' in by_id[r.id].meta.needs;
		let why = null;
		let i = 0;

		// Each family is taken as it is checked, a scrape's hundreds in one
		// pass: a run that may not write one gives back what it took.
		for (let name in r.families) {
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
