'use strict';

// What each program of the package loads, by its static imports: the
// handler, which uhttpd runs per scrape, and the rpcd plugin, which rpcd
// keeps loaded, never load the command line's parser. And a module split into
// a directory is imported through the module in front of it.

import { describe, it, assert } from 'utest';
import { readfile, lsdir, stat } from 'fs';
import * as loader from 'prometheus_exporter.loader';

const IMPORT = /(^|\n)[ \t]*import[^'"\n;]*from[ \t]*(['"])([^'"]+)['"]/g;

// The module names a source imports.
function imports_of(text) {
	return map(match(text ?? '', IMPORT) ?? [], (m) => m[3]);
}

// Every module `path`'s program loads, statically: its imports, and theirs,
// of the exporter's own modules, followed into src/.
function loaded_by(path) {
	let seen = {};
	let queue = imports_of(readfile(path));

	while (length(queue)) {
		let name = shift(queue);

		if (seen[name])
			continue;
		seen[name] = true;

		if (substr(name, 0, 20) == 'prometheus_exporter.')
			push(queue, ...imports_of(readfile(`src/${replace(name, '.', '/')}.uc`)));
	}

	return sort(keys(seen));
}

describe('what the programs load', () => {
	it('finds the imports it follows', () => {
		assert.match(true, 'prometheus_exporter.app' in loaded_by('files/usr/libexec/prometheus-exporter/handler.uc'));
		assert.match(true, 'docopt' in loaded_by('files/usr/bin/prometheus-exporter'));
	});

	// ucode makes a closure in a step for each function its program compiled
	// before the closure's own, and the recorder makes closures for each
	// collector a scrape runs and each family it writes: its module is the
	// handler's program's first, by app's first import.
	it('compiles the recorder\'s module first in the handler\'s program', () => {
		assert.match([ 'prometheus_exporter.app', 'prometheus_exporter.exposition' ], [
			imports_of(readfile('files/usr/libexec/prometheus-exporter/handler.uc'))[0],
			imports_of(readfile('src/prometheus_exporter/app.uc'))[0],
		]);
	});

	// uhttpd holds what the handler's program loads for as long as it runs:
	// the loader, which checks the collectors, it compiles as a program of
	// its own, and lets go of (prometheus_exporter.app's load).
	it('never keeps the loader in the handler\'s program, nor what only it needs', () => {
		let loaded = loaded_by('files/usr/libexec/prometheus-exporter/handler.uc');

		assert.match([], filter([ 'prometheus_exporter.loader', 'prometheus_exporter.jail', 'prometheus_exporter.loader.imports' ],
			(m) => m in loaded));
	});

	it('never loads docopt in the handler, rpcd or the helpers rpcd runs', () => {
		for (let path in [
			'files/usr/libexec/prometheus-exporter/handler.uc',
			'files/usr/share/rpcd/ucode/prometheus-exporter.uc',
			'files/usr/libexec/prometheus-exporter/rpc-status.uc',
			'files/usr/libexec/prometheus-exporter/probe.uc',
		])
			assert.match(false, 'docopt' in loaded_by(path), path);
	});
});

// A module split into a directory of its own (exposition.uc and exposition/)
// is the directory's facade: the modules of exposition/ are its, and only it,
// they themselves and each one's own unit test (test/unit/prometheus_exporter/
// exposition/<module>_test.uc) import them. Everything else takes what the
// facade exports. collectors/ has no facade: collectors are loaded by name.
const ANY_IMPORT = /import[^'"\n;]*from[ \t]*(['"])([^'"]+)['"]/g;
const INTERNAL = /^prometheus_exporter\.([a-z_]+)\.([a-z0-9_]+)$/;
const SCANNED = [ 'src', 'files', 'devenv/scripts', 'test' ];
const SKIPPED = [ 'test/fixtures', 'test/browser', 'devenv/scripts/node_modules' ];

// The paths of the files under `dir` whose imports are scanned: ucode's, the
// shell scripts that run ucode -e, and the command line.
function files_under(dir, out) {
	for (let name in sort(lsdir(dir) ?? [])) {
		let path = `${dir}/${name}`;

		if (path in SKIPPED)
			continue;
		if (stat(path)?.type == 'directory')
			files_under(path, out);
		else if (match(name, /\.(uc|sh)$/) || path == 'files/usr/bin/prometheus-exporter')
			push(out, path);
	}

	return out;
}

// The directories of src/prometheus_exporter that a module of the same name fronts.
function facades() {
	return filter(lsdir('src/prometheus_exporter') ?? [], (d) =>
		stat(`src/prometheus_exporter/${d}`)?.type == 'directory' && stat(`src/prometheus_exporter/${d}.uc`)?.type == 'file');
}

// What is wrong of `importer` importing module `name`, or null when nothing
// is: an internal module of one of `fronted`'s directories, from outside.
function boundary_problem(importer, name, fronted) {
	let m = match(name, INTERNAL);

	if (!m || !(m[1] in fronted))
		return null;
	if (importer == `src/prometheus_exporter/${m[1]}.uc` || index(importer, `src/prometheus_exporter/${m[1]}/`) == 0 ||
	    importer == `test/unit/prometheus_exporter/${m[1]}/${m[2]}_test.uc`)
		return null;

	return `${importer} imports ${name}, which is internal to prometheus_exporter.${m[1]}: import prometheus_exporter.${m[1]}, which exports what others take of it`;
}

describe('modules split into a directory', () => {
	it('are imported only by their facade, each other and their own tests', () => {
		let fronted = facades();
		let problems = [];

		for (let dir in SCANNED)
			for (let path in files_under(dir, []))
				for (let m in match(readfile(path) ?? '', ANY_IMPORT) ?? []) {
					let problem = boundary_problem(path, m[2], fronted);

					if (problem)
						push(problems, problem);
				}

		assert.match([], problems);
	});

	it('the rule catches an import from outside the directory, and lets the rest through', () => {
		let fronted = [ 'deps' ];

		assert.match([
			'src/prometheus_exporter/app.uc imports prometheus_exporter.deps.exec, which is internal to prometheus_exporter.deps: import prometheus_exporter.deps, which exports what others take of it',
			'test/unit/prometheus_exporter/deps/ubus_test.uc imports prometheus_exporter.deps.exec, which is internal to prometheus_exporter.deps: import prometheus_exporter.deps, which exports what others take of it',
			'test/lib/commands.uc imports prometheus_exporter.deps.exec, which is internal to prometheus_exporter.deps: import prometheus_exporter.deps, which exports what others take of it',
			null, null, null, null, null, null,
		], [
			boundary_problem('src/prometheus_exporter/app.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('test/unit/prometheus_exporter/deps/ubus_test.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('test/lib/commands.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('src/prometheus_exporter/deps.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('src/prometheus_exporter/deps/ubus.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('test/unit/prometheus_exporter/deps/exec_test.uc', 'prometheus_exporter.deps.exec', fronted),
			boundary_problem('src/prometheus_exporter/app.uc', 'prometheus_exporter.deps', fronted),
			boundary_problem('devenv/scripts/e2e.sh', 'prometheus_exporter.collectors.diskstats', fronted),
			boundary_problem('src/prometheus_exporter/app.uc', 'prometheus_exporter.rpc.validate', fronted),
		]);
	});

	it('scans the programs, the scripts and the tests, and finds the facades', () => {
		let scanned = [ ...files_under('src', []), ...files_under('files', []), ...files_under('devenv/scripts', []), ...files_under('test', []) ];

		assert.match(true, length(filter([
			'files/usr/libexec/prometheus-exporter/handler.uc', 'files/usr/bin/prometheus-exporter',
			'files/usr/share/rpcd/ucode/prometheus-exporter.uc', 'devenv/scripts/docs_gen/harvest.uc',
			'devenv/scripts/package-check.sh', 'test/lib/commands.uc', 'test/context.uc',
		], (p) => !(p in scanned))) == 0);
		assert.match(true, 'exposition' in facades() && !('collectors' in facades()));
	});
});

// A collector imports the collector API alone, and loads no code past it: the
// loader leaves out one that does (loader.import_problem), so each the
// packages ship must keep to it.
describe('what the collectors import', () => {
	it('is the collector API alone, for each collector the packages ship', () => {
		let problems = [];

		for (let path in files_under('src/prometheus_exporter/collectors', [])) {
			let why = loader.import_problem(readfile(path));

			if (why != null)
				push(problems, `${path}: ${why}`);
		}

		assert.match([], problems);
		assert.match(true, length(files_under('src/prometheus_exporter/collectors', [])) >= length(loader.OWN));
	});

	// A collector's top level runs again in uhttpd's own process, unguarded
	// but for collection.top_level: it only declares (loader.purity_problem).
	it('only declares at its top level, for each collector the packages ship and each the checks install', () => {
		let problems = [];
		let paths = [ ...files_under('src/prometheus_exporter/collectors', []), ...files_under('test/fixtures/luci/collectors', []) ];

		for (let path in paths) {
			let why = loader.purity_problem(readfile(path));

			if (why != null)
				push(problems, `${path}: ${why}`);
		}

		assert.match([], problems);
		assert.match(true, length(paths) > length(loader.OWN));
	});

	// The collectors the checks install (the browser's sampler, runner and
	// hostile) are loaded as any other: one the loader refuses is missing from
	// the pages the tests look at, and every test of it fails for that alone.
	it('is the collector API alone, in strict mode, for each collector the checks install', () => {
		let problems = [];
		let paths = files_under('test/fixtures/luci/collectors', []);

		for (let path in paths) {
			let why = loader.refusal(readfile(path));

			if (why != null)
				push(problems, `${path}: ${why}`);
		}

		assert.match([], problems);
		assert.match(true, length(paths) > 0);
	});
});
