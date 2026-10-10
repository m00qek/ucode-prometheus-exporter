'use strict';

// The generated reference pages of a checkout, and what keeps them from being
// written: see devenv/scripts/docs-gen.uc.

import * as loader from 'prometheus.exporter.loader';
import { USAGE } from 'prometheus.exporter.cli';
import * as package from 'docs_gen.package';
import * as harvest from 'docs_gen.harvest';
import * as pages from 'docs_gen.pages';
import * as migration from 'docs_gen.migration';

export const OUT = 'docs/reference';
export const NOTES = 'docs/gen/notes.uc';
export const COLLECTORS = 'src/prometheus/collectors';

// The modules and programs whose text says which error codes they raise.
const RAISERS = [
	'src/prometheus/exporter/*.uc',
	'src/prometheus/exporter/*/*.uc',
	'src/prometheus/collectors/*.uc',
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

// What the migration page is written from: { notes, inventory, template },
// docs/gen/migration.uc, docs/gen/feed-exporters.json and docs/gen/migration.md.
export function load_migration(fs) {
	return {
		notes: load_notes(`${fs.getcwd()}/${migration.NOTES}`),
		inventory: json(fs.readfile(migration.INVENTORY) ?? die(`no ${migration.INVENTORY}`)),
		template: fs.readfile(migration.TEMPLATE) ?? die(`no ${migration.TEMPLATE}`),
	};
};

// What the pages are written from (the ctx of docs_gen.pages), of the
// checkout in the current directory, and the problems found gathering it:
// { ctx, problems }. fs is the fs module; notes, the notes module. `loaded`
// is load_collectors()'s, to load them once for several runs: ucode keeps the
// source of each module a load compiles open. `migrating` is load_migration()'s,
// read when null.
export function context(fs, notes, loaded, migrating) {
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
		errors: fs.readfile('src/prometheus/exporter/errors.uc'),
		usage: USAGE,
		migration: migrating ?? load_migration(fs),
	};

	return { ctx, problems };
};

// { pages: { path: text }, problems: [ message ] } of the checkout in the
// current directory, as context() takes its arguments.
export function run(fs, notes, loaded, migrating) {
	let gathered = context(fs, notes, loaded, migrating);
	let ctx = gathered.ctx, problems = gathered.problems;
	let out = {};

	for (let p in [
		[ 'collectors.md', pages.collectors_page ],
		[ 'metrics.md', pages.metrics_page ],
		[ 'uci-config.md', pages.uci_page ],
		[ 'error-codes.md', pages.errors_page ],
		[ 'command.md', pages.command_page ],
		[ 'migration.md', migration.migration_page ],
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
