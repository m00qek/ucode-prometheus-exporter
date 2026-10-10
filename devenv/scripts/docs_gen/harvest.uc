'use strict';

// The metric families the collectors write, as they write them: each collector
// run as a scrape runs it, on each fixture set (docs_gen.fixtures), once with
// its defaults and once more for each boolean option the other way round. What
// a family is (its type, help and label names) is read back from the text the
// scrape would send, never from the code.

import * as deps from 'prometheus.exporter.deps';
import * as scrape from 'prometheus.exporter.scrape';
import * as exposition from 'prometheus.exporter.exposition';
import * as config from 'prometheus.exporter.config';
import * as Result from 'prometheus.exporter.result';
import * as fixtures from 'docs_gen.fixtures';

export const ROOT = 'test/fixtures';

// The fixture sets the collectors run on: every directory of ROOT that is one
// (it has captures of ubus, of /proc or of /sys), sorted.
export function sets(fs, root) {
	let out = [];

	for (let name in sort(fs.lsdir(root) ?? [])) {
		let dir = `${root}/${name}`;

		if (length(filter([ 'ubus', 'proc', 'sys' ], (d) => fs.stat(`${dir}/${d}`)?.type == 'directory')))
			push(out, name);
	}

	return out;
};

function quiet() {
	return null;
}

// The ways collector `meta` is run: { option, section }, with its defaults
// first (option null), then with each boolean option set the other way:
// option 'leases=1', section { leases: '1' }.
export function variants(meta) {
	let out = [ { option: null, section: null } ];

	for (let name in sort(keys(meta.options ?? {}))) {
		let spec = meta.options[name];

		if (type(spec.default) == 'bool') {
			let value = spec.default ? '0' : '1';

			push(out, { option: `${name}=${value}`, section: { [name]: value } });
		}
	}

	return out;
};

// The families of one run of collector `c` on the modules `mods`:
// { result, families }, families as exposition.parse() reads them.
export function run_with(mods, c) {
	let session = deps.session({ ...mods, log: quiet });
	let env = { session: () => session, clock: () => [ 0, 0 ], log: quiet };
	let r = scrape.run_one(env, session, c);

	session.close();

	let parsed = exposition.parse(exposition.render(r.families));

	if (!parsed.ok)
		die(`${c.meta.name} wrote invalid exposition text: ${Result.describe(parsed)}`);

	return { result: r.result, families: parsed.data };
};

function overlay(c, variant) {
	return variant.section ? { [config.NAME]: { [c.id]: { '.type': 'collector', ...variant.section } } } : {};
}

// A family as the reference lists it: { name, type, help, labels, sets,
// options }: label names in the order first seen; the sets it was seen on, and
// the options it needs (empty when the defaults write it).
function family_of(f) {
	return { name: f.name, type: f.type, help: f.help, labels: [], sets: [], options: [], defaults: false };
}

// Adds what `families` (parse()'s) holds to `into` ({ name: family }), seen on
// set `set` with `option` (null for the defaults). Disagreements go to
// `problems`.
export function add(into, families, set, option, collector, problems) {
	for (let f in families) {
		let have = into[f.name];

		if (!have)
			have = into[f.name] = family_of(f);
		else if (have.type != f.type)
			push(problems, `${collector}: ${f.name} is a ${have.type} and a ${f.type}`);
		else if (have.help != f.help)
			push(problems, `${collector}: ${f.name} has two help texts: ${sprintf('%J', have.help)} and ${sprintf('%J', f.help)}`);

		for (let s in f.samples)
			for (let pair in s.labels)
				if (!(pair[0] in have.labels))
					push(have.labels, pair[0]);

		if (!(set in have.sets))
			push(have.sets, set);
		if (option == null)
			have.defaults = true;
		else if (!(option in have.options))
			push(have.options, option);
	}
};

// The families a scrape writes of itself: node_exporter's
// node_scrape_collector_* and the exporter's own, from a scrape of the first
// collector on the first set.
function own_families(fs, root, collectors) {
	let set = sets(fs, root)[0];
	let mods = fixtures.modules(`${root}/${set}`, {});
	let env = {
		session: () => deps.session({ ...mods, log: quiet }),
		clock: () => [ 0, 0 ],
		log: quiet,
		version: 'dev',
	};
	let c = collectors[0];
	let res = scrape.scrape(env, [ c ], '');
	let parsed = exposition.parse(res.body);
	let own = {};
	let order = [];
	let written = map(run_with(mods, c).families, (f) => f.name);
	let problems = [];

	for (let f in parsed.data) {
		if (f.name in written)
			continue;
		push(order, f.name);
		add(own, [ f ], set, null, 'scrape', problems);
	}

	return map(order, function(n) {
		let f = own[n];

		delete f.defaults;
		f.sets = [];
		return f;
	});
}

// { families: { collector: [ family ] }, own: [ family ], outcomes, problems }:
// what every collector of `collectors` wrote on the fixture sets of `root`, in
// the order first seen, and the exporter's own families, which a scrape writes
// whoever ran; `outcomes` is how each run went: { collector: { set: text } }.
// A family that only an option writes keeps those options; one the defaults
// write has none.
export function harvest(fs, root, collectors) {
	let problems = [];
	let by = {};
	let order = {};
	let outcomes = {};

	for (let c in collectors) {
		by[c.meta.name] = {};
		order[c.meta.name] = [];
		outcomes[c.meta.name] = {};
	}

	for (let set in sets(fs, root)) {
		let dir = `${root}/${set}`;

		for (let c in collectors) {
			let seen = by[c.meta.name];

			for (let v in variants(c.meta)) {
				let r = run_with(fixtures.modules(dir, overlay(c, v)), c);

				if (v.option == null)
					outcomes[c.meta.name][set] = r.result.ok
						? (Result.is_none(r.result) ? `nothing to observe: ${r.result.none}` : 'ok')
						: Result.describe(r.result);

				for (let f in r.families)
					if (!seen[f.name])
						push(order[c.meta.name], f.name);
				add(seen, r.families, set, v.option, c.meta.name, problems);
			}
		}
	}

	let families = {};

	for (let c in collectors) {
		let seen = by[c.meta.name];

		families[c.meta.name] = map(order[c.meta.name], function(n) {
			let f = seen[n];

			if (f.defaults)
				f.options = [];
			delete f.defaults;
			return f;
		});
	}

	return { families, own: own_families(fs, root, collectors), outcomes, problems };
};
