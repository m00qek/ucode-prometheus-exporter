/**
 * The collectors' modules as ucode loads them: their directory, a module's
 * name, and its exports, loaded alone or with others as one program; and a
 * meta's fingerprint, which tells a meta from the one checked in another
 * process. What the loader (prometheus_exporter.loader), which checks the
 * modules, and the handler, which serves them, both take: the handler loads
 * the modules the loader checked without the loader, which it never keeps
 * (see prometheus_exporter.app's load).
 *
 * @module prometheus_exporter_collection
 */

'use strict';

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
 * A module's exports, by name. require() cannot load an ES module, but a
 * script that imports one can.
 *
 * @param {string} id the module's name, in the collectors' directory.
 * @returns {CollectorModule} its exports; it throws what loading it throws.
 */
export function import_module(id) {
	return loadstring(sprintf('import * as c from %J;\nreturn c;', 'prometheus_exporter.collectors.' + id),
		{ raw_mode: true })();
};

/**
 * The exports of each of the modules `ids`, by name, compiled as ONE
 * program: what they import, the collector API and the core's modules
 * behind it, is compiled once for them all, and kept once. import_module
 * compiles a program a module, and with it a copy of all it imports, whose
 * source files ucode keeps open while the copy lives: six files a collector.
 * One module that does not compile or load fails them all.
 *
 * @param {string[]} ids the modules' names, in the collectors' directory.
 * @returns {Object<string, CollectorModule>} each one's exports, by name; it
 *   throws what loading any of them throws.
 */
export function import_modules(ids) {
	let lines = map(ids, (id, i) => sprintf('import * as c%d from %J;', i, 'prometheus_exporter.collectors.' + id));
	let mods = loadstring(join('\n', lines) + sprintf('\nreturn [ %s ];', join(', ', map(ids, (id, i) => `c${i}`))),
		{ raw_mode: true })();
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
 * Why the outcome of loading a module in the probe's child process
 * (prometheus_exporter.probe) leaves it out, as the exporter logs it, or
 * null when it does not: it hung, or did not load.
 *
 * @param {string} id the module's name.
 * @param {?ProbeOutcome} p the outcome, or null for none.
 * @returns {?string} why, or null.
 */
export function left_out(id, p) {
	if (p?.hung)
		return `collector '${id}' hung at load: ${p.error}; it is left out`;
	if (p != null && !p.ok)
		return `cannot load collector '${id}': ${p.error}`;

	return null;
};

/**
 * A meta's fingerprint: its JSON, functions and all, as ucode writes them
 * (their signatures). The same module loaded twice gives the same meta, and
 * so the same fingerprint, unless what its top level does changed in
 * between. The text itself, not a digest of it: the handler compares them
 * when it starts, and a digest would have it load ucode-mod-digest, which
 * uhttpd would then hold for as long as it runs.
 *
 * @param {Meta} meta the meta, as the loader takes it (options {} when it
 *   declares none).
 * @returns {string} its fingerprint.
 */
export function fingerprint(meta) {
	return sprintf('%J', meta);
};
