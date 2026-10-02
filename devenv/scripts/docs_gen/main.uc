'use strict';

// The generated reference pages of a checkout, and what keeps them from being
// written: see devenv/scripts/docs-gen.uc.

import * as loader from 'prometheus_exporter.loader';
import { USAGE } from 'prometheus_exporter.cli';
import * as package from 'docs_gen.package';
import * as harvest from 'docs_gen.harvest';
import * as pages from 'docs_gen.pages';

export const OUT = 'docs/reference';
export const NOTES = 'docs/gen/notes.uc';
export const COLLECTORS = 'src/prometheus_exporter/collectors';

// The modules and programs whose text says which error codes they raise.
const RAISERS = [
	'src/prometheus_exporter/*.uc',
	'src/prometheus_exporter/*/*.uc',
	'src/prometheus_exporter/collectors/*.uc',
	'files/usr/libexec/prometheus-exporter/*.uc',
	'files/usr/share/rpcd/ucode/*.uc',
];

// The module of the notes, by its path.
export function load_notes(path) {
	return loadstring(sprintf('import * as n from %J;\nreturn n;', path), { raw_mode: true })();
};

// The collectors of the checkout, as the exporter loads them; and what the
// loader left out, as problems.
export function load_collectors(fs, problems) {
	return loader.load(fs, COLLECTORS, loader.import_module,
		(level, msg) => push(problems, `the loader left a collector out: ${msg}`));
};

// { pages: { path: text }, problems: [ message ] } of the checkout in the
// current directory: fs is the fs module; notes, the notes module. `loaded`
// is load_collectors()'s, to load them once for several runs: ucode keeps the
// source of each module a load compiles open.
export function run(fs, notes, loaded) {
	let pkg = package.parse(fs.readfile(package.MAKEFILE) ?? die(`no ${package.MAKEFILE}`));
	let problems = [];
	let collectors = loaded ?? load_collectors(fs, problems);
	let places = {};
	let name_of = {};
	let sources = {};

	for (let c in collectors) {
		places[c.id] = package.placement(pkg, c.id, c.meta.name);
		name_of[c.id] = c.meta.name;
		sources[c.id] = fs.readfile(`${COLLECTORS}/${c.id}.uc`);

		if (!places[c.id])
			push(problems, `${c.meta.name} is in no package of ${package.MAKEFILE}`);
	}

	let raisers = {};

	for (let pattern in RAISERS)
		for (let path in fs.glob(pattern) ?? [])
			raisers[path] = fs.readfile(path);

	let ctx = {
		pkg, collectors, places, name_of, sources, notes, raisers,
		sets: harvest.sets(fs, harvest.ROOT),
		harvest: harvest.harvest(fs, harvest.ROOT, collectors),
		errors: fs.readfile('src/prometheus_exporter/errors.uc'),
		usage: USAGE,
	};

	let out = {};

	for (let p in [
		[ 'collectors.md', pages.collectors_page ],
		[ 'metrics.md', pages.metrics_page ],
		[ 'uci-config.md', pages.uci_page ],
		[ 'error-codes.md', pages.errors_page ],
		[ 'command.md', pages.command_page ],
	]) {
		let res = p[1](ctx);

		out[`${OUT}/${p[0]}`] = res.text;
		push(problems, ...res.problems);
	}

	return { pages: out, problems: uniq(problems) };
};

// The pages of `pages` whose file does not hold that text, sorted.
export function stale(fs, pages) {
	return sort(filter(keys(pages), (path) => fs.readfile(path) !== pages[path]));
};
