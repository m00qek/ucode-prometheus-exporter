/**
 * The collectors' modules as ucode loads them: their directory, a module's
 * name, and its exports, loaded alone or with others as one program, their
 * top level guarded (top_level); and a meta's fingerprint, which tells a meta
 * from the one checked in another process. What the loader
 * (prometheus_exporter.loader), which checks the modules, and the handler,
 * which serves them, both take: the handler loads the modules the loader
 * checked without the loader, which it never keeps (see
 * prometheus_exporter.app's load).
 *
 * @module prometheus_exporter_collection
 */

'use strict';

import { md5 } from 'digest';
import * as errors from 'prometheus_exporter.errors';

/**
 * The installed collectors' directory, as the packages install them.
 *
 * @type {string}
 */
export const DIR = '/usr/share/ucode/prometheus_exporter/collectors';

/**
 * A collector's module name: its name (meta.name) with _ for -.
 *
 * @param {string} name a collector's name (meta.name).
 * @returns {string} its module's name: name with _ for -.
 */
export function id_of(name) {
	return replace(name, '-', '_');
};

/**
 * What ucode's functions a collector's top level may not call do, by name:
 * while it runs, each is replaced by one that refuses it (top_level()). They
 * block, end, or write to the process that loads it, load code, which reads
 * files and reaches every module (a top level that require()s fs reads what
 * it likes), or change how it takes a signal. The collector API's exposition
 * functions load the exposition format with loadstring, the first time one
 * is called: at the top level, that is refused too.
 *
 * @type {Object<string, string>}
 */
export const TRAPPED = {
	sleep: 'blocks the process',
	system: 'runs a program',
	exit: 'ends the process',
	print: 'writes to the process\'s output',
	printf: 'writes to the process\'s output',
	warn: 'writes to the process\'s output',
	trace: 'writes to the process\'s output',
	require: 'loads code, and through it reads files, runs programs and opens sockets',
	include: 'loads code',
	loadfile: 'loads code',
	loadstring: 'loads code, as the collector API\'s exposition functions do the first time one is called',
	render: 'loads code, or writes to the process\'s output',
	signal: 'changes how the process takes a signal',
};

/**
 * The prefix of what top_level() throws: the code a collector whose top
 * level did more than declare is left out with.
 *
 * @type {string}
 */
export const IMPURE = errors.COLLECTOR_IMPURE;

// What replaces ucode's function `name` while a top level runs: it refuses
// the call, and keeps in st.refused the first it refused. Made here, not in
// top_level()'s loop, whose closures would all see its last name.
function trap(st, name, does) {
	return function() {
		st.refused ??= `${IMPURE} (its top level called ${name}(), which ${does}: ` +
			'a collector\'s top level only declares, and leaves what it does to collect())';
		die(st.refused);
	};
}

/**
 * Runs `program`, a compiled program whose top level is collector modules'
 * (loadstring's, of their imports), with each of ucode's functions of
 * TRAPPED replaced by one that refuses it, and gives back what it returns.
 * The functions are themselves again once it is done, whatever it did.
 *
 * A collector's top level runs twice when it is loaded: in the probe's child
 * process, guarded (prometheus_exporter.probe), and then in the process that
 * serves the scrapes, uhttpd's, where nothing stops it. Both run it here. In
 * the child, what it calls is refused before it runs, and the probe leaves the
 * module out; and should it call one in uhttpd that it did not in the child,
 * the second load leaves it out the same way, rather than the call blocking,
 * ending or writing to the process every scrape is forked from.
 *
 * A call refused throws `COLLECTOR_IMPURE (its top level called <name>(),
 * which <does>: ...)`, and so does the program, after it, if the module caught
 * that. What the program throws of its own, it throws.
 *
 * @param {function(): *} program the compiled program.
 * @returns {*} what it returns.
 */
export function top_level(program) {
	let saved = {};
	let st = { refused: null };

	for (let name, does in TRAPPED) {
		saved[name] = global[name];
		global[name] = trap(st, name, does);
	}

	let out, error = null;

	try {
		out = program();
	} catch (e) {
		error = e.message;
	}

	for (let name, fn in saved)
		global[name] = fn;

	if (st.refused != null)
		die(st.refused);
	if (error != null)
		die(error);

	return out;
};

/**
 * A module's exports, by name. require() cannot load an ES module, but a
 * script that imports one can. Its top level runs guarded (top_level()).
 *
 * @param {string} id the module's name, in the collectors' directory.
 * @returns {CollectorModule} its exports; it throws what loading it throws.
 */
export function import_module(id) {
	return top_level(loadstring(sprintf('import * as c from %J;\nreturn c;', 'prometheus_exporter.collectors.' + id),
		{ raw_mode: true }));
};

/**
 * A module's exports, by its path, as `collector check` loads a module not
 * installed yet: as import_module() loads one by name, its top level guarded.
 *
 * @param {string} path the module's file.
 * @returns {CollectorModule} its exports; it throws what loading it throws.
 */
export function import_path(path) {
	return top_level(loadstring(sprintf('import * as c from %J;\nreturn c;', path), { raw_mode: true }));
};

/**
 * The exports of each of the modules `ids`, by name, compiled as ONE
 * program: what they import, the collector API and the core's modules
 * behind it, is compiled once for them all, and kept once. import_module
 * compiles a program a module, and with it a copy of all it imports, whose
 * source files ucode keeps open while the copy lives: six files a collector.
 * One module that does not compile or load fails them all. Their top level
 * runs guarded (top_level()).
 *
 * @param {string[]} ids the modules' names, in the collectors' directory.
 * @returns {Object<string, CollectorModule>} each one's exports, by name; it
 *   throws what loading any of them throws.
 */
export function import_modules(ids) {
	let lines = map(ids, (id, i) => sprintf('import * as c%d from %J;', i, 'prometheus_exporter.collectors.' + id));
	let mods = top_level(loadstring(join('\n', lines) + sprintf('\nreturn [ %s ];', join(', ', map(ids, (id, i) => `c${i}`))),
		{ raw_mode: true }));
	let out = {};

	for (let i = 0; i < length(ids); i++)
		out[ids[i]] = mods[i];

	return out;
};

/**
 * The module names in `dir`, sorted.
 *
 * @param {module:fs} fs what lists the directory: an object of fs's lsdir.
 * @param {string} dir the directory.
 * @returns {string[]} the names of its [a-z0-9_]+.uc files, without .uc.
 */
export function discover(fs, dir) {
	let files = filter(fs.lsdir(dir) ?? [], (f) => match(f, /^[a-z0-9_]+\.uc$/));

	return sort(map(files, (f) => substr(f, 0, -3)));
};

/**
 * A module the loader checked in a child process (the loader's
 * check_module): its name, the fingerprint of its meta as the loader took it
 * there (fingerprint()), and whether it is one of the exporter's own.
 *
 * @typedef {{ id: string, meta: string, own: boolean }} CheckedModule
 */

/**
 * What the exporter logs of module `id`, which loading threw `error` of (its
 * first line): `skipping collector: COLLECTOR_IMPURE (<id>: ...)` for a top
 * level that did more than declare (top_level()), and `cannot load collector
 * '<id>': <error>` for anything else.
 *
 * @param {string} id the module's name.
 * @param {string} error the first line of what loading it threw.
 * @returns {string} the message.
 */
export function load_error(id, error) {
	let m = match(error, /^([A-Z_]+) \((.*)\)$/);

	if (m && m[1] == IMPURE)
		return `skipping collector: ${IMPURE} (${id}: ${m[2]})`;

	return `cannot load collector '${id}': ${error}`;
};

/**
 * Why the outcome of loading a module in the probe's child process
 * (prometheus_exporter.probe) leaves it out, as the exporter logs it, or
 * null when it does not: it hung, or did not load (load_error()).
 *
 * @param {string} id the module's name.
 * @param {?ProbeOutcome} p the outcome, or null for none.
 * @returns {?string} why, or null.
 */
export function left_out(id, p) {
	if (p?.hung)
		return `collector '${id}' hung at load: ${p.error}; it is left out`;
	if (p != null && !p.ok)
		return load_error(id, p.error ?? 'it did not load');

	return null;
};

/**
 * A meta's fingerprint: the MD5 of its JSON, functions and all, as ucode
 * writes them (their signatures). The same module loaded twice gives the
 * same meta, and so the same fingerprint, unless what its top level does
 * changed in between.
 *
 * @param {Meta} meta the meta, as the loader takes it (options {} when it
 *   declares none).
 * @returns {string} its fingerprint.
 */
export function fingerprint(meta) {
	return md5(sprintf('%J', meta));
};
