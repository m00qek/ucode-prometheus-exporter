/**
 * What the ubus object's `collectors` says of each installed collector, for LuCI.
 *
 * @module prometheus_exporter_rpc_describe
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as config from 'prometheus.exporter.config';
import { NAME, PACKAGE } from 'prometheus.exporter.config';
import * as loader from 'prometheus.exporter.loader';
import * as jail from 'prometheus.exporter.jail';
import { collector_value, message } from 'prometheus.exporter.rpc.validate';

/**
 * An option of a collector's entry: its spec, value, whether it is set, and its error.
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
 * A collector's entry in `collectors`.
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

/** apk's lists of each package's files (sys.apk). */
export const APK_LISTS = '/lib/apk/packages';

/**
 * A string that is not empty, or null.
 *
 * @param {*} value
 * @returns {?string}
 */
export function text(value) {
	return (type(value) == 'string' && value != '') ? value : null;
};

/**
 * One option of meta.options, a bare default or { default, title, help, datatype }.
 *
 * @param {string} name
 * @param {*} decl
 * @returns {OptionEntry}
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
 * @param {Meta} meta
 * @returns {OptionEntry[]}
 */
export function options_of(meta) {
	let options = meta.options ?? {};

	return map(keys(options), (name) => option_spec(name, options[name]));
};

/**
 * A short label: meta.title, or the collector's name.
 *
 * @param {Meta} meta
 * @returns {string}
 */
export function title_of(meta) {
	return text(meta.title) ?? meta.name;
};

/**
 * { path: package } for the files of the exporter's packages, from apk's lists.
 *
 * @param {module:fs} fs
 * @param {string} dir
 * @returns {Object<string, string>}
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
		error: j.options.ok ? null : Result.describe(j.options),
	};
}

/**
 * What `collectors` answers: each installed collector, and those the loader left out.
 *
 * @param {RpcSys} sys
 * @returns {{ collectors: CollectorEntry[], skipped: string[] }}
 */
export function collectors(sys) {
	let owner_of = owners(sys.fs, sys.apk ?? APK_LISTS);

	return {
		collectors: map(sys.collectors, (c) => collector_entry(sys, c, owner_of)),
		skipped: sys.skipped ?? [],
	};
};
