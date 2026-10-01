'use strict';

// Finds the installed collectors: every module in the collectors directory that
// exports a valid `meta` and a `collect`. One that does not load or is not valid
// is logged and left out, so a broken subpackage costs only its own collector.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { NEEDS } from 'node_exporter.deps';

export const DIR = '/usr/share/ucode/node_exporter/collectors';

const NAME = /^[a-z0-9][a-z0-9_-]*$/;
const OPTION_TYPES = [ 'bool', 'int', 'string' ];

// The module a collector's name lives in: a module name cannot hold '-'.
export function id_of(name) {
	return replace(name, '-', '_');
};

// A module's exports, by name. require() cannot load an ES module, but a
// script that imports one can.
export function import_module(id) {
	return loadstring(sprintf('import * as c from %J;\nreturn c;', 'node_exporter.collectors.' + id),
		{ raw_mode: true })();
};

function invalid(id, msg) {
	return Result.err(errors.COLLECTOR_INVALID, `${id}: ${msg}`);
}

function is_strings(v) {
	return type(v) == 'array' && length(filter(v, (s) => type(s) != 'string' || s == '')) == 0;
}

// { id, meta, collect } for a module's exports, or COLLECTOR_INVALID.
export function validate(id, mod) {
	let meta = mod?.meta;

	if (type(meta) != 'object')
		return invalid(id, 'exports no meta');
	if (type(meta.name) != 'string' || !match(meta.name, NAME) || id_of(meta.name) != id)
		return invalid(id, `meta.name must be '${id}', or it with '-' for '_'`);
	if (type(meta.help) != 'string' || meta.help == '')
		return invalid(id, 'meta.help must be a sentence');
	if (!is_strings(meta.needs) || length(uniq(meta.needs)) != length(meta.needs))
		return invalid(id, 'meta.needs must list capabilities once each');

	for (let need in meta.needs)
		if (!(need in NEEDS))
			return invalid(id, `unknown need '${need}'`);

	if ('exec' in meta.needs) {
		if (!is_strings(meta.commands) || !length(meta.commands))
			return invalid(id, 'meta.commands must list the programs exec runs');
	} else if (meta.commands != null) {
		return invalid(id, 'meta.commands without exec in meta.needs');
	}

	if (meta.options != null && type(meta.options) != 'object')
		return invalid(id, 'meta.options must be an object of defaults');

	for (let key, fallback in meta.options)
		if (!(type(fallback) in OPTION_TYPES) || !match(key, /^[a-z][a-z0-9_]*$/))
			return invalid(id, `option '${key}' needs a boolean, integer or string default`);

	if (type(mod.collect) != 'function')
		return invalid(id, 'exports no collect function');

	return Result.ok({ id, meta: { options: {}, ...meta }, collect: mod.collect });
};

// The module names in `dir`, sorted.
export function discover(fs, dir) {
	let files = filter(fs.lsdir(dir) ?? [], (f) => match(f, /^[a-z0-9_]+\.uc$/));

	return sort(map(files, (f) => substr(f, 0, -3)));
};

// What identifies the collector files in `dir` as they are now: their names,
// sizes and change times. Installing, removing or upgrading one changes it.
export function fingerprint(fs, dir) {
	return join('\n', map(discover(fs, dir), function(id) {
		let st = fs.stat(`${dir}/${id}.uc`);
		return `${id} ${st?.size} ${st?.mtime}`;
	}));
};

// The valid collectors in `dir`, sorted by name.
export function load(fs, dir, import_fn, log) {
	let collectors = [];

	for (let id in discover(fs, dir)) {
		let mod;

		try {
			mod = import_fn(id);
		} catch (e) {
			log(`cannot load collector '${id}': ${split(e.message, '\n')[0]}`);
			continue;
		}

		let res = validate(id, mod);
		if (!res.ok) {
			log(`skipping collector: ${Result.describe(res)}`);
			continue;
		}

		push(collectors, res.data);
	}

	return sort(collectors, (a, b) => a.meta.name < b.meta.name ? -1 : 1);
};
