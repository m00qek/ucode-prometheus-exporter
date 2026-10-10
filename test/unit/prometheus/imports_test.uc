'use strict';

// What each program of the package loads, by its static imports: the
// handler, which uhttpd runs per scrape, and the rpcd plugin, which rpcd
// keeps loaded, never load the command line's parser. And the module tree:
//
// - src/prometheus/exporter.uc is prometheus.exporter, the collector API, the
//   one module a collector imports (by that exact name), and the modules
//   of its own package's (none: a collector is a single module);
// - src/prometheus/exporter/ is the core, prometheus.exporter.<x>: its modules
//   import each other as siblings, never the collector API nor a collector;
// - the entry points (the init script, the libexec programs, the rpcd
//   plugins, the command line and uci-defaults) import any module of the core;
// - src/prometheus/collectors/ is the collectors', prometheus.collectors.<x>,
//   which the loader imports by name;
// - and a module split into a directory is imported through the module in
//   front of it.

import { describe, it, assert } from 'utest';
import { readfile, lsdir, stat } from 'fs';
import * as loader from 'prometheus.exporter.loader';

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

		if (substr(name, 0, 11) == 'prometheus.')
			push(queue, ...imports_of(readfile(`src/${replace(name, '.', '/')}.uc`)));
	}

	return sort(keys(seen));
}

describe('what the programs load', () => {
	it('finds the imports it follows', () => {
		assert.match(true, 'prometheus.exporter.app' in loaded_by('files/usr/libexec/prometheus-exporter/handler.uc'));
		assert.match(true, 'docopt' in loaded_by('files/usr/bin/prometheus-exporter'));
	});

	// ucode makes a closure in a step for each function its program compiled
	// before the closure's own, and the recorder makes closures for each
	// collector a scrape runs and each family it writes: its module is the
	// handler's program's first, by app's first import.
	it('compiles the recorder\'s module first in the handler\'s program', () => {
		assert.match([ 'prometheus.exporter.app', 'prometheus.exporter.exposition' ], [
			imports_of(readfile('files/usr/libexec/prometheus-exporter/handler.uc'))[0],
			imports_of(readfile('src/prometheus/exporter/app.uc'))[0],
		]);
	});

	// uhttpd holds what the handler's program loads for as long as it runs:
	// the loader, which checks the collectors, it compiles as a program of
	// its own, and lets go of (prometheus.exporter.app's load).
	it('never keeps the loader in the handler\'s program, nor what only it needs', () => {
		let loaded = loaded_by('files/usr/libexec/prometheus-exporter/handler.uc');

		assert.match([], filter([ 'prometheus.exporter.loader', 'prometheus.exporter.jail', 'prometheus.exporter.loader.imports' ],
			(m) => m in loaded));
	});

	// Nor what only some scrapes, or some routers, need: basic auth and the
	// hashes it computes (when the config sets it), the exposition parser
	// (two collectors), and the native modules collectors need, which each
	// loads where it runs (deps.native).
	it('never keeps in the handler\'s program what it loads when it is needed', () => {
		let loaded = loaded_by('files/usr/libexec/prometheus-exporter/handler.uc');

		assert.match([], filter([
			'prometheus.exporter.auth', 'prometheus.exporter.crypt', 'digest',
			'prometheus.exporter.exposition.parse', 'ubus', 'rtnl', 'nl80211', 'socket',
		], (m) => m in loaded));
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

	// The command line is a package of its own, ucode-prometheus-exporter-cli,
	// with its modules and docopt: what the base package ships runs without
	// it, the init script's check included.
	it('never loads the command line\'s modules, nor docopt, in what the base package ships', () => {
		let cli = [ 'docopt', 'prometheus.exporter.cli', 'prometheus.exporter.conform' ];
		let programs = [
			...map(filter(lsdir('files/usr/libexec/prometheus-exporter') ?? [], (f) => match(f, /\.uc$/)), (f) => `files/usr/libexec/prometheus-exporter/${f}`),
			...map(lsdir('files/usr/share/rpcd/ucode') ?? [], (f) => `files/usr/share/rpcd/ucode/${f}`),
			...map(filter(lsdir('src/prometheus/exporter') ?? [], (f) => match(f, /\.uc$/) && !(f in [ 'cli.uc', 'conform.uc' ])),
				(f) => `src/prometheus/exporter/${f}`),
			'src/prometheus/exporter.uc',
		];
		let problems = [];

		for (let path in programs)
			for (let m in cli)
				if (m in loaded_by(path))
					push(problems, `${path} loads ${m}`);

		assert.match([], problems);
		assert.match(true, 'files/usr/libexec/prometheus-exporter/check.uc' in programs);
		assert.match(true, 'prometheus.exporter.conform' in loaded_by('files/usr/bin/prometheus-exporter'));
	});

	it('runs the init script\'s check without the command line', () => {
		let init = readfile('files/etc/init.d/prometheus-exporter');

		assert.match([ null, true ], [ match(init, /\/usr\/bin\/|\$COMMAND/), index(init, 'CHECK=$LIBEXEC/check.uc') >= 0 ]);
	});
});

// A module split into a directory of its own (exposition.uc and exposition/)
// is the directory's facade: the modules of exposition/ are its, and only it,
// they themselves and each one's own unit test (test/unit/prometheus/exporter/
// exposition/<module>_test.uc) import them. Everything else takes what the
// facade exports. collectors/ has no facade: collectors are loaded by name.
// Nor is exporter.uc exporter/'s: it is the collector API, and the core's
// modules are anyone's in the tree but a collector's.
const ANY_IMPORT = /import[^'"\n;]*from[ \t]*(['"])([^'"]+)['"]/g;
const INTERNAL = /^prometheus\.exporter\.([a-z_]+)\.([a-z0-9_]+)$/;
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

// The directories of src/prometheus/exporter that a module of the same name fronts.
function facades() {
	return filter(lsdir('src/prometheus/exporter') ?? [], (d) =>
		stat(`src/prometheus/exporter/${d}`)?.type == 'directory' && stat(`src/prometheus/exporter/${d}.uc`)?.type == 'file');
}

// What is wrong of `importer` importing module `name`, or null when nothing
// is: an internal module of one of `fronted`'s directories, from outside.
function boundary_problem(importer, name, fronted) {
	let m = match(name, INTERNAL);

	if (!m || !(m[1] in fronted))
		return null;
	if (importer == `src/prometheus/exporter/${m[1]}.uc` || index(importer, `src/prometheus/exporter/${m[1]}/`) == 0 ||
	    importer == `test/unit/prometheus/exporter/${m[1]}/${m[2]}_test.uc`)
		return null;

	return `${importer} imports ${name}, which is internal to prometheus.exporter.${m[1]}: import prometheus.exporter.${m[1]}, which exports what others take of it`;
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
			'src/prometheus/exporter/app.uc imports prometheus.exporter.deps.exec, which is internal to prometheus.exporter.deps: import prometheus.exporter.deps, which exports what others take of it',
			'test/unit/prometheus/exporter/deps/ubus_test.uc imports prometheus.exporter.deps.exec, which is internal to prometheus.exporter.deps: import prometheus.exporter.deps, which exports what others take of it',
			'test/lib/commands.uc imports prometheus.exporter.deps.exec, which is internal to prometheus.exporter.deps: import prometheus.exporter.deps, which exports what others take of it',
			null, null, null, null, null, null,
		], [
			boundary_problem('src/prometheus/exporter/app.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('test/unit/prometheus/exporter/deps/ubus_test.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('test/lib/commands.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('src/prometheus/exporter/deps.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('src/prometheus/exporter/deps/ubus.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('test/unit/prometheus/exporter/deps/exec_test.uc', 'prometheus.exporter.deps.exec', fronted),
			boundary_problem('src/prometheus/exporter/app.uc', 'prometheus.exporter.deps', fronted),
			boundary_problem('devenv/scripts/e2e.sh', 'prometheus.collectors.diskstats', fronted),
			boundary_problem('src/prometheus/exporter/app.uc', 'prometheus.exporter.rpc.validate', fronted),
		]);
	});

	it('scans the programs, the scripts and the tests, and finds the facades', () => {
		let scanned = [ ...files_under('src', []), ...files_under('files', []), ...files_under('devenv/scripts', []), ...files_under('test', []) ];

		assert.match(true, length(filter([
			'files/usr/libexec/prometheus-exporter/handler.uc', 'files/usr/bin/prometheus-exporter',
			'files/usr/share/rpcd/ucode/prometheus-exporter.uc', 'devenv/scripts/docs_gen/harvest.uc',
			'devenv/scripts/package-check.sh', 'src/prometheus/exporter/devkit/commands.uc', 'src/prometheus/exporter/devkit/collector.uc',
		], (p) => !(p in scanned))) == 0);
		assert.match(true, 'exposition' in facades() && !('collectors' in facades()));
	});
});

// The modules of the tree each import a module by the name it has there:
// prometheus.exporter, prometheus.exporter.<x> or prometheus.collectors.<x>,
// a file of src/ (or of the template collector package's).
const TREE = /^prometheus(\.|$)/;
const API = 'prometheus.exporter';
const CORE = 'prometheus.exporter.';
const ENTRY_POINTS = [ 'files/etc', 'files/usr/bin', 'files/usr/libexec', 'files/usr/share/rpcd' ];

// Every `prometheus` module each file under `dirs` imports: [ path, name ].
function tree_imports(dirs) {
	let out = [];

	for (let dir in dirs)
		for (let path in files_under(dir, []))
			for (let m in match(readfile(path) ?? '', ANY_IMPORT) ?? [])
				if (match(m[2], TREE))
					push(out, [ path, m[2] ]);

	return out;
}

// Whether module `name` is a file of the tree.
function exists(name) {
	let path = replace(name, '.', '/');

	return stat(`src/${path}.uc`)?.type == 'file' || stat(`devkit/template/src/${path}.uc`)?.type == 'file';
}

// Whether module `name` is one of the core's.
function is_core(name) {
	return substr(name, 0, length(CORE)) == CORE && exists(name);
}

describe('the module tree', () => {
	// The test cases may name a module that is not there, to see it refused;
	// make lint compiles each, so none imports one by a stale name.
	it('names modules that are there, in the programs, the scripts and the tests\' helpers', () => {
		let problems = [];

		for (let i in tree_imports([ 'src', 'files', 'devenv/scripts', 'test/lib', 'test/bench' ]))
			if (!exists(i[1]))
				push(problems, `${i[0]} imports ${i[1]}, which is no module of src/`);

		assert.match([], problems);
	});

	it('has the core\'s modules import each other as siblings, never the collector API nor a collector', () => {
		let problems = [];

		for (let i in tree_imports([ 'src/prometheus/exporter' ]))
			if (!is_core(i[1]))
				push(problems, `${i[0]} imports ${i[1]}: a module of the core imports the core's, prometheus.exporter.<x>`);

		assert.match([], problems);
		assert.match(true, length(tree_imports([ 'src/prometheus/exporter' ])) > 0);
	});

	it('has the collector API take what it exports from the core', () => {
		let found = tree_imports([ 'src/prometheus' ]);
		let own = map(filter(found, (i) => i[0] == 'src/prometheus/exporter.uc'), (i) => i[1]);

		assert.match(true, length(own) > 0);
		assert.match([], filter(own, (n) => !is_core(n)));
	});

	it('has the entry points import the core\'s modules', () => {
		let found = tree_imports(ENTRY_POINTS);

		assert.match([], map(filter(found, (i) => !is_core(i[1])), (i) => `${i[0]} imports ${i[1]}`));
		for (let p in [ 'files/usr/bin/prometheus-exporter', 'files/usr/libexec/prometheus-exporter/handler.uc',
		                'files/usr/share/rpcd/ucode/prometheus-exporter.uc' ])
			assert.match(true, length(filter(found, (i) => i[0] == p)) > 0, p);
	});

	it('tells the core\'s modules from the collector API, the collectors and what is not there', () => {
		assert.match([ true, true, false, false, false, false ], map([
			'prometheus.exporter.scrape', 'prometheus.exporter.deps.exec', API, 'prometheus.collectors.loadavg',
			'prometheus.exporter.nope', 'prometheus_exporter.scrape',
		], is_core));
		assert.match([ true, true, true, false ], map([ API, 'prometheus.collectors.loadavg', 'prometheus.collectors.example', 'prometheus' ], exists));
	});

	it('loads the collectors by name from prometheus/collectors', () => {
		assert.match([ API, '/usr/share/ucode/prometheus/collectors' ], [ loader.API, loader.DIR ]);
	});
});

// A collector imports the collector API alone, and loads no code past it: the
// loader leaves out one that does (loader.import_problem), so each the
// packages ship must keep to it.
describe('what the collectors import', () => {
	it('is the collector API by its exact name: no module of the core, nor another collector', () => {
		let module = (name) => `'use strict';\nimport * as x from '${name}';\n`;

		assert.match(null, loader.import_problem(module(API)));
		for (let name in [ 'prometheus.exporter.scrape', 'prometheus.exporter.deps', 'prometheus.exporter.result',
		                   'prometheus.collectors.loadavg', 'prometheus', 'prometheus.exporters', 'prometheus_exporter.api' ])
			assert.match(true, loader.import_problem(module(name)) != null, name);
	});

	it('is the collector API alone, for each collector the packages ship', () => {
		let problems = [];

		for (let path in [ ...files_under('src/prometheus/collectors', []), ...files_under('devkit/template/src/prometheus/collectors', []) ]) {
			let why = loader.import_problem(readfile(path));

			if (why != null)
				push(problems, `${path}: ${why}`);
		}

		assert.match([], problems);
		assert.match(true, length(files_under('src/prometheus/collectors', [])) >= length(loader.OWN));
	});

	// A collector's top level runs again in uhttpd's own process, unguarded
	// but for collection.top_level: it only declares (loader.purity_problem).
	it('only declares at its top level, for each collector the packages ship and each the checks install', () => {
		let problems = [];
		let paths = [ ...files_under('src/prometheus/collectors', []), ...files_under('test/fixtures/luci/collectors', []) ];

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
