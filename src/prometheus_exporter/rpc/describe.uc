/**
 * What the ubus object's `collectors` says of each installed collector, for
 * LuCI (prometheus_exporter.rpc): its options as the exporter reads them
 * from the configuration as saved, its package, and what its jail gives it.
 *
 *   collector: { name, id, title, help, enabled, package, base, options: [ option ],
 *                needs, configs, commands, jail: { paths, owned, commands, mounts, problems, missing,
 *                ubus, capabilities, groups, proc_files }, error }
 *   option:    { name, core, title, type, default, help, datatype, value, set, error }
 *
 * options are the collector's own, in the order it declares them, then the
 * core's `timeout` (core: true) when it runs programs: the seconds they get in
 * each scrape. Its default is the collector's meta.timeout or else the main
 * section's exec_timeout, which `default_from` names ('meta.timeout' or
 * 'exec_timeout'). The core's `enabled` is the collector's own field.
 *
 * sys: prometheus_exporter.rpc's.
 *
 * @module prometheus_exporter_rpc_describe
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import { NAME, PACKAGE } from 'prometheus_exporter.config';
import * as loader from 'prometheus_exporter.loader';
import * as jail from 'prometheus_exporter.jail';
import { collector_value, message } from 'prometheus_exporter.rpc.validate';

/**
 * An option, as the module's top comment lays it out: option_spec's, and in
 * a collector's entry its value, whether its section sets it, and what is
 * wrong with it; the core's timeout also has `default_from`. Its default and
 * value are a boolean, an integer or a string, as its default sets.
 *
 * @typedef {{
 *   name: string,
 *   core: boolean,
 *   title: string,
 *   type: ?string,
 *   default: ?(boolean|int|string),
 *   default_from: ?string,
 *   help: ?string,
 *   datatype: ?string,
 *   value: ?(boolean|int|string),
 *   set: ?boolean,
 *   error: ?string
 * }} OptionEntry
 */

/**
 * A collector, as the module's top comment lays it out.
 *
 * @typedef {{
 *   name: string,
 *   id: string,
 *   title: string,
 *   help: string,
 *   enabled: boolean,
 *   package: ?string,
 *   base: ?boolean,
 *   options: OptionEntry[],
 *   needs: string[],
 *   configs: string[],
 *   commands: string[],
 *   jail: { paths: string[], owned: string[], commands: Object<string, ?string>, mounts: string[], problems: string[], missing: string[],
 *     ubus: Object<string, string[]>, capabilities: string[], groups: string[], proc_files: string[] },
 *   error: ?string
 * }} CollectorEntry
 */

/**
 * apk's lists of each package's files (sys.apk).
 *
 * @type {string}
 */
export const APK_LISTS = '/lib/apk/packages';

/**
 * A string that is not empty, or null.
 *
 * @param {*} value anything; only a string that is not empty is kept.
 * @returns {?string} it, or null.
 */
export function text(value) {
	return (type(value) == 'string' && value != '') ? value : null;
};

/**
 * One option of meta.options, in either shape: a bare default (`stations: true`),
 * or { default, title, help, datatype }. datatype names LuCI's datatypes, and
 * 'regex'. Its title is the option's name when it declares none.
 *
 * @param {string} name the option's name.
 * @param {*} decl its declaration: { default, title, help, datatype }, or a
 *   bare default of any type.
 * @returns {OptionEntry} the option, without a value.
 */
export function option_spec(name, decl) {
	let spec = (type(decl) == 'object') ? decl : { default: decl };

	return {
		name,
		core: false,
		title: text(spec.title) ?? name,
		type: type(spec.default),
		default: spec.default,
		help: text(spec.help),
		datatype: text(spec.datatype),
	};
};

/**
 * meta.options as a list, in the order the collector declares them.
 *
 * @param {Meta} meta the collector's meta.
 * @returns {OptionEntry[]} its options, without values.
 */
export function options_of(meta) {
	let options = meta.options ?? {};

	return map(keys(options), (name) => option_spec(name, options[name]));
};

/**
 * A short label: meta.title, or the collector's name.
 *
 * @param {Meta} meta the collector's meta.
 * @returns {string} the label.
 */
export function title_of(meta) {
	return text(meta.title) ?? meta.name;
};

/**
 * { path: package } for the files of the exporter's packages: apk keeps a list
 * of each package's files.
 *
 * @param {module:fs} fs what reads the lists: an object of fs's glob and
 *   readfile.
 * @param {string} dir apk's lists' directory (APK_LISTS).
 * @returns {Object<string, string>} each file's package, by path.
 */
export function owners(fs, dir) {
	let out = {};

	for (let list in fs.glob(`${dir}/${PACKAGE}*.list`) ?? []) {
		let pkg = replace(substr(list, length(dir) + 1), /\.list$/, '');

		for (let path in split(fs.readfile(list) ?? '', '\n'))
			if (path != '')
				out[path] = pkg;
	}

	return out;
};

function option_entry(c, spec, section) {
	let set = (spec.name in keys(section));
	let res = collector_value(c, spec.name, set ? section[spec.name] : null);

	return {
		...spec,
		value: res.ok ? res.data : section[spec.name],
		set,
		error: res.ok ? null : message(spec.name, res),
	};
}

// The core's timeout of a collector that runs programs, whose default follows
// the configuration as saved: meta.timeout, or else the main section's
// exec_timeout.
function timeout_entry(sys, c, section) {
	let set = ('timeout' in keys(section));
	let fallback = config.default_timeout(sys.uci, c.meta);
	let res = set ? collector_value(c, 'timeout', section.timeout) : Result.ok(fallback);

	return {
		name: 'timeout',
		core: true,
		title: config.TIMEOUT.title,
		type: 'int',
		default: fallback,
		default_from: (c.meta.timeout != null) ? 'meta.timeout' : 'exec_timeout',
		help: config.TIMEOUT.help,
		datatype: config.TIMEOUT.datatype,
		value: res.ok ? res.data : section.timeout,
		set,
		error: res.ok ? null : message('timeout', res),
	};
}

function collector_entry(sys, c, owner_of) {
	let meta = c.meta;
	let j = jail.collector(c, sys);
	let owner = owner_of[`${sys.dir ?? loader.DIR}/${c.id}.uc`];
	let section = sys.uci.get_all(NAME, c.id);

	if (type(section) != 'object' || section['.type'] != 'collector')
		section = {};

	return {
		name: meta.name,
		id: c.id,
		title: title_of(meta),
		help: meta.help,
		enabled: j.enabled,
		package: owner ?? null,
		base: (owner == null) ? null : owner == PACKAGE,
		options: [
			...map(options_of(meta), (spec) => option_entry(c, spec, section)),
			...(('exec' in meta.needs) ? [ timeout_entry(sys, c, section) ] : []),
		],
		needs: meta.needs,
		configs: meta.configs ?? [],
		commands: meta.commands ?? [],
		jail: {
			paths: j.paths, owned: j.owned, commands: j.commands, mounts: j.mounts, problems: j.problems, missing: j.missing,
			ubus: j.ubus, capabilities: j.capabilities, groups: j.groups, proc_files: j.proc_files,
		},
		// The section's first invalid option (or enabled), as the exporter reports it.
		error: j.options.ok ? null : Result.describe(j.options),
	};
}

/**
 * What the ubus object's `collectors` answers: each installed collector,
 * and what the loader logged of those it left out.
 *
 * @param {RpcSys} sys the system.
 * @returns {{ collectors: CollectorEntry[], skipped: string[] }} them.
 */
export function collectors(sys) {
	let owner_of = owners(sys.fs, sys.apk ?? APK_LISTS);

	return {
		collectors: map(sys.collectors, (c) => collector_entry(sys, c, owner_of)),
		skipped: sys.skipped ?? [],
	};
};
