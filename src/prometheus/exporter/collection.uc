/**
 * The collectors' modules as ucode loads them, their top level guarded.
 *
 * @module prometheus_exporter_collection
 */

'use strict';

import * as errors from 'prometheus.exporter.errors';

/**
 * The installed collectors' directory, as the packages install them.
 *
 * @type {string}
 */
export const DIR = '/usr/share/ucode/prometheus/collectors';

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
 * What each function a collector's top level may not call does, by name.
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
 * The prefix of what top_level() throws.
 *
 * @type {string}
 */
export const IMPURE = errors.COLLECTOR_IMPURE;

function trap(st, name, does) {
	return function() {
		st.refused ??= `${IMPURE} (its top level called ${name}(), which ${does}: ` +
			'a collector\'s top level only declares, and leaves what it does to collect())';
		die(st.refused);
	};
}

const IMMUTABLE = 'value is immutable';

function same(a, b) {
	return a === b || (a != a && b != b);
}

function restore(saved) {
	let changed = [];

	for (let name in keys(global))
		if (!exists(saved, name)) {
			push(changed, name);
			delete global[name];
		}

	for (let name, v in saved) {
		if (!(name in TRAPPED) && (!exists(global, name) || !same(global[name], v)))
			push(changed, name);
		global[name] = v;
	}

	return sort(changed);
}

/**
 * Runs `program` with each function of TRAPPED replaced by one that refuses it, and the global scope as it was after.
 *
 * @param {function(): *} program the compiled program.
 * @returns {*} what it returns.
 */
export function top_level(program) {
	let saved = {};
	let st = { refused: null };

	for (let name, v in global)
		saved[name] = v;
	for (let name, does in TRAPPED)
		global[name] = trap(st, name, does);

	let out, error = null;

	try {
		out = program();
	} catch (e) {
		error = e.message;
	}

	let changed = restore(saved);

	if (st.refused != null)
		die(st.refused);
	if (length(changed))
		die(`${IMPURE} (its top level changed the global scope, ${join(', ', changed)}: ` +
			'a collector\'s top level only declares, and leaves what it does to collect())');
	if (error != null && index(error, IMMUTABLE) >= 0)
		die(`${IMPURE} (its top level wrote over what the collector API exports, which no collector may change: ${split(error, '\n')[0]})`);
	if (error != null)
		die(error);

	return out;
};

/**
 * A module's exports, by name.
 *
 * @param {string} id the module's name, in the collectors' directory.
 * @returns {CollectorModule} its exports; it throws what loading it throws.
 */
export function import_module(id) {
	return top_level(loadstring(sprintf('import * as c from %J;\nreturn c;', 'prometheus.collectors.' + id),
		{ raw_mode: true }));
};

/**
 * A module's exports, by its path, its top level guarded.
 *
 * @param {string} path the module's file.
 * @returns {CollectorModule} its exports; it throws what loading it throws.
 */
export function import_path(path) {
	return top_level(loadstring(sprintf('import * as c from %J;\nreturn c;', path), { raw_mode: true }));
};

/**
 * The exports of each of the modules `ids`, by name, compiled as one program.
 *
 * @param {string[]} ids the modules' names, in the collectors' directory.
 * @returns {Object<string, CollectorModule>} their exports, by name; throws what loading throws.
 */
export function import_modules(ids) {
	let lines = map(ids, (id, i) => sprintf('import * as c%d from %J;', i, 'prometheus.collectors.' + id));
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
 * A module the loader checked in a child process.
 *
 * @typedef {{ id: string, meta: string, own: boolean }} CheckedModule
 */

/**
 * What the exporter logs of module `id`, whose loading threw `error`.
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
 * Why the probe's outcome for a module leaves it out, or null when it does not.
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
 * A meta's fingerprint: its JSON, functions and all, as ucode writes them (their signatures).
 *
 * @param {Meta} meta the meta, as the loader takes it (options {} when it declares none).
 * @returns {string} its fingerprint.
 */
export function fingerprint(meta) {
	return sprintf('%J', meta);
};
