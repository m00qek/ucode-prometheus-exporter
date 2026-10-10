'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as ownership from 'prometheus.exporter.ownership';
import * as Result from 'prometheus.exporter.result';

// own() as its comment says it, a family at a time: what its check of all
// the families at once must agree with.
function reference(runs, by_id) {
	let owners = {};
	let failed = {};
	let mine = (r) => r.id in [ 'cpu', 'loadavg', 'exporter' ];

	for (let r in [ ...filter(runs, mine), ...filter(runs, (r) => !mine(r)) ]) {
		let taken = [];

		for (let name in r.families) {
			let why = null;

			if (substr(name, 0, length(ownership.SCRAPE_PREFIX)) == ownership.SCRAPE_PREFIX)
				why = 'scrape';
			else if (substr(name, 0, length(ownership.EXPORTER_PREFIX)) == ownership.EXPORTER_PREFIX)
				why = 'exporter';
			else if (owners[name] != null && owners[name] != r.name)
				why = 'taken';

			if (why) {
				for (let t in taken)
					delete owners[t];
				failed[r.name] = true;
				break;
			}

			if (owners[name] == null)
				push(taken, name);
			owners[name] = r.name;
		}
	}

	return map(runs, (r) => failed[r.name] ? 'FAMILY_CONFLICT' : 'ok');
}

const NAMES = [ 'a', 'b', 'c', 'node_load1', 'node_scrape_collector_x', 'ucode_prometheus_exporter_y', 'ucode_prometheus_exporterz' ];

function runs_of(spec) {
	let by_id = {};
	let runs = map(spec, function(s, i) {
		// The exporter's own collectors (loader.OWN) once each, as a scrape
		// runs a collector once.
		let id = [ 'cpu', 'loadavg', 'exporter', 'other', 'third' ][s[0]];

		if (s[0] > 2 || by_id[id] != null)
			id = `other${i}`;

		by_id[id] = { id, meta: { name: id, needs: (id == 'exporter') ? [ 'exporter' ] : [] }, own: id in [ 'cpu', 'loadavg', 'exporter' ] };
		return { name: id, id, result: Result.ok(), families: uniq(map(s[1], (k) => NAMES[k])), samples: 1, text: 'x\n' };
	});

	return { runs, by_id };
}

describe('ownership.own', () => {
	it('changes no run whose families no other writes, and none of the core\'s', () => {
		let x = runs_of([ [ 0, [ 0, 1 ] ], [ 3, [ 2 ] ], [ 2, [ 6 ] ] ]);
		let logs = [];

		ownership.own({ log: (l, m) => push(logs, m) }, x.runs, x.by_id);
		assert.match([ [ 'ok', 'ok', 'ok' ], [] ], [ map(x.runs, (r) => r.result.ok ? 'ok' : r.result.error), logs ]);
	});

	// The scrape writes the exporter's families itself, the ledger's
	// counters too: no collector may, the exporter's own included.
	it('keeps the exporter\'s families from every collector, the exporter collector\'s included', () => {
		let x = runs_of([ [ 2, [ 5 ] ] ]);

		ownership.own({ log: () => null }, x.runs, x.by_id);
		assert.match('FAMILY_CONFLICT (ucode_prometheus_exporter_y belongs to the exporter itself)', Result.describe(x.runs[0].result));
	});

	prop('fails the runs the families\' owners, taken a family at a time, would fail',
		gen.array(gen.tuple(gen.int(0, 4), gen.array(gen.int(0, length(NAMES) - 1), { min_len: 0, max_len: 4 })), { min_len: 1, max_len: 6 }),
		(spec) => {
			let x = runs_of(spec);
			let want = reference(x.runs, x.by_id);

			ownership.own({ log: () => null }, x.runs, x.by_id);
			assert.match(want, map(x.runs, (r) => r.result.ok ? 'ok' : r.result.error), sprintf('%J', spec));
		}, { runs: 300 });
});
