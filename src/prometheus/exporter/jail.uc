/**
 * What procd's jail mounts for the exporter: what its enabled collectors declare.
 *
 * @module prometheus_exporter_jail
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as config from 'prometheus.exporter.config';
import * as privileges from 'prometheus.exporter.privileges';
import * as grant from 'prometheus.exporter.grant';
import { uci_handles } from 'prometheus.exporter.deps';
import { DIR as STATE_DIR } from 'prometheus.exporter.state';

/**
 * What the jail's functions take of the system: a uci cursor, fs, and a PATH.
 *
 * @typedef {{ uci: UciCursor, fs: module:fs, path: ?string }} JailSys
 */

/**
 * What one collector gets in the jail, as collector() gives it.
 *
 * @typedef {{
 *   enabled: boolean,
 *   options: Result<Object>,
 *   configs: string[],
 *   paths: string[],
 *   owned: string[],
 *   commands: Object<string, ?string>,
 *   mounts: string[],
 *   problems: string[],
 *   missing: string[],
 *   ubus: Object<string, string[]>,
 *   capabilities: string[],
 *   groups: string[],
 *   proc_files: string[]
 * }} CollectorJail
 */

/** Where uci's configs are. */
export const CONFIG_DIR = '/etc/config';

/** The exporter's own config, which every jail has. */
export const OWN_CONFIG = `${CONFIG_DIR}/${config.NAME}`;

/** popen's shell, which a collector that runs programs gets. */
export const SHELL = '/bin/sh';

/** The ubus socket, which procd's jail option `ubus` mounts. */
export const UBUS_SOCKET = '/var/run/ubus/ubus.sock';

/** The service's own read-only mounts, which every instance has. */
export const SERVICE = [
	'/usr/lib/uhttpd_ucode.so', '/lib/libubus.so*', '/lib/libuci.so*', '/usr/lib/libnl*.so*', '/usr/lib/libz.so*',
	'/usr/lib/ucode', '/usr/share/ucode/prometheus', `/usr/libexec/${config.NAME}/handler.uc`, SHELL,
];

/** What procd's jail options and ujail itself give every instance. */
export const GIVEN = [
	'/proc', '/sys', '/dev/log',
	'/dev/null', '/dev/zero', '/dev/full', '/dev/random', '/dev/urandom', '/etc/resolv.conf',
];

/** What every jail of the service has, whatever its collectors declare. */
export const COMMON = [ ...GIVEN, ...SERVICE, OWN_CONFIG, STATE_DIR ];

/** procd's PATH, which the jailed uhttpd and so popen's shell have. */
export const PATH = '/usr/sbin:/usr/bin:/sbin:/bin';

/** Directories that hold what belongs to every service: never mounted whole for one collector. */
export const BROAD = [
	'/', '/bin', '/dev', '/etc', '/etc/config', '/lib', '/proc', '/run', '/sbin', '/sys', '/tmp', '/tmp/run',
	'/usr', '/usr/bin', '/usr/lib', '/usr/sbin', '/usr/share', '/var', '/var/run',
];

const PLACEHOLDER = /\{([a-z][a-z0-9_]*)\}/g;

/**
 * Why `path` cannot be a mount, or null.
 *
 * @param {*} path
 * @returns {?string}
 */
export function path_problem(path) {
	if (type(path) != 'string' || substr(path, 0, 1) != '/')
		return `${sprintf('%J', path)} is not an absolute path`;
	if (match(path, /[[:space:][:cntrl:]*?[]/))
		return `${sprintf('%J', path)} holds a space, a control or a glob character`;
	if (path != '/' && (match(path, /\/\/|\/\.\.?(\/|$)/) || substr(path, -1) == '/'))
		return `${path} is not a plain path (no //, . or .., nor a trailing /)`;
	if (path in BROAD)
		return `${path} is too broad to mount for one collector`;

	return null;
};

/**
 * Why the exporter cannot make and mount `path` as its own, or null.
 *
 * @param {*} path
 * @returns {?string}
 */
export function owned_problem(path) {
	let why = path_problem(path);

	if (why == null && !config.is_owned_directory(path))
		why = `${path} is not under ${join(', ', config.OWNED_ROOTS)}: the service makes and mounts no other directory`;

	return why;
};

/**
 * The option names a path of meta.paths holds as {name}.
 *
 * @param {string} template
 * @returns {string[]}
 */
export function placeholders(template) {
	return map(match(template, PLACEHOLDER) ?? [], (m) => m[1]);
};

/**
 * A path of meta.paths with its {option}s filled in, or null when one of them is not a string.
 *
 * @param {string} template
 * @param {?Object} options
 * @returns {?string}
 */
export function fill(template, options) {
	let missing = false;
	let p = replace(template, PLACEHOLDER, function(m, name) {
		let v = options?.[name];

		if (type(v) != 'string') {
			missing = true;
			return '';
		}

		return v;
	});

	return missing ? null : p;
};

/**
 * Where the shell finds `cmd` on `search` (a PATH), or null.
 *
 * @param {module:fs} fs
 * @param {string} search
 * @param {string} cmd
 * @returns {?string}
 */
export function which(fs, search, cmd) {
	if (index(cmd, '/') >= 0)
		return fs.stat(cmd)?.type == 'file' ? cmd : null;

	for (let dir in split(search, ':'))
		if (dir != '' && fs.stat(`${dir}/${cmd}`)?.type == 'file')
			return `${dir}/${cmd}`;

	return null;
};

function call_paths(fn, options, handles) {
	let got;

	try {
		got = fn(options, handles);
	} catch (e) {
		return { problem: `a paths function failed: ${split(e.message, '\n')[0]}` };
	}

	if (type(got) != 'array')
		return { problem: `a paths function returned ${type(got) ?? 'null'}, not an array` };

	return { paths: got };
}

/**
 * meta.paths for these typed options and uci handles: the paths, the owned ones, the problems.
 *
 * @param {Meta} meta
 * @param {Object} options
 * @param {Object<string, UciHandle>} handles
 * @returns {{ paths: string[], owned: string[], problems: string[] }}
 */
export function resolve_paths(meta, options, handles) {
	let paths = [];
	let owned = [];
	let problems = [];

	for (let entry in meta.paths ?? []) {
		let got;
		let own = false;

		if (type(entry) == 'object') {
			own = entry.owned === true;
			entry = entry.path;
		}

		if (type(entry) == 'function') {
			got = call_paths(entry, options, handles);
			if (got.problem) {
				push(problems, got.problem);
				continue;
			}
			got = got.paths;
		} else {
			let p = fill(entry, options);
			if (p == null) {
				push(problems, `${entry}: an option it names is not a string`);
				continue;
			}
			if (length(p) > 1 && substr(p, -1) == '/')
				p = rtrim(p, '/') || '/';
			got = [ p ];
		}

		for (let p in got) {
			let why = own ? owned_problem(p) : path_problem(p);

			if (why) {
				push(problems, why);
				continue;
			}

			push(paths, p);
			if (own)
				push(owned, p);
		}
	}

	return { paths: sort(uniq(paths)), owned: sort(uniq(owned)), problems };
};

/**
 * What one collector gets in the jail, and what its user may do there.
 *
 * @param {Collector} c
 * @param {JailSys} sys
 * @returns {CollectorJail}
 */
export function collector(c, sys) {
	let meta = c.meta;
	let options = config.collector(sys.uci, c.id, meta);
	let configs = map(meta.configs ?? [], (n) => `${CONFIG_DIR}/${n}`);
	let paths = [];
	let owned = [];
	let problems = [];
	let commands = {};

	if (options.ok) {
		let r = resolve_paths(meta, options.data, uci_handles(() => sys.uci, meta.configs ?? []));
		paths = r.paths;
		owned = r.owned;
		problems = r.problems;
	} else if (length(meta.paths ?? [])) {
		push(problems, `its paths are not known: ${Result.describe(options)}`);
	}

	let calls = privileges.ubus_of(meta, options.ok ? options.data : {});

	push(problems, ...calls.problems);

	let missing = filter(paths, (p) => !(p in owned) && sys.fs.stat(p) == null);
	let mounts = [ ...configs, ...filter(paths, (p) => !(p in missing)) ];

	if ('exec' in meta.needs) {
		push(mounts, SHELL);

		for (let cmd in meta.commands) {
			let found = which(sys.fs, sys.path ?? PATH, cmd);

			commands[cmd] = found;
			if (found)
				push(mounts, found);
			else if (!(cmd in (meta.optional_commands ?? [])))
				push(problems, `command ${cmd} is not on ${sys.path ?? PATH}`);
		}
	}

	return {
		enabled: config.enabled(sys.uci, c.id),
		options, configs, paths, owned, commands,
		mounts: sort(uniq(mounts)),
		problems,
		missing,
		ubus: calls.ubus,
		capabilities: meta.capabilities ?? [],
		groups: meta.groups ?? [],
		proc_files: meta.proc_files ?? [],
	};
};

/**
 * The jail's mounts, problems, missing and owned paths for these installed collectors.
 *
 * @param {Collector[]} collectors
 * @param {JailSys} sys
 * @returns {{ mounts: string[], problems: string[], missing: string[], owned: string[] }}
 */
export function mounts(collectors, sys) {
	let all = [ OWN_CONFIG ];
	let problems = [];
	let missing = [];
	let owned = [];

	for (let c in collectors) {
		if (!config.enabled(sys.uci, c.id))
			continue;

		let j = collector(c, sys);

		push(all, ...j.mounts);
		if ('ubus' in c.meta.needs)
			push(all, UBUS_SOCKET);
		push(missing, ...j.missing);
		push(owned, ...j.owned);
		for (let p in j.problems)
			push(problems, `${c.meta.name}: ${p}`);
	}

	return { mounts: sort(uniq(all)), problems, missing: sort(uniq(missing)), owned: sort(uniq(owned)) };
};

/**
 * What the service's user may do in the jail of these collectors, for grant's make().
 *
 * @param {Collector[]} collectors
 * @param {JailSys} sys
 * @returns {Grants}
 */
export function grants(collectors, sys) {
	let ubus = [], capabilities = [], groups = [], groups_off = [];
	let files = [ OWN_CONFIG ], files_off = [], problems = [];

	for (let c in collectors) {
		let meta = c.meta;

		if (!config.enabled(sys.uci, c.id)) {
			push(groups_off, ...(meta.groups ?? []));
			push(files_off, ...map(meta.configs ?? [], (n) => `${CONFIG_DIR}/${n}`), ...(meta.proc_files ?? []));
			continue;
		}

		let j = collector(c, sys);

		push(ubus, j.ubus);
		push(capabilities, ...j.capabilities);
		push(groups, ...j.groups);
		push(files, ...j.configs, ...j.proc_files);
		for (let p in j.problems)
			push(problems, `${meta.name}: ${p}`);
	}

	let svc = config.service_values(sys.uci);
	let cert = svc.ok ? svc.data.cert : '', key = svc.ok ? svc.data.key : '';
	let tls = (cert != '' && key != '') ? { cert, key } : null;
	let usable = (tls != null);

	for (let name in (tls ? [ 'cert', 'key' ] : [])) {
		let p = config.tls_problem(sys.fs, tls[name]);

		if (p)
			push(problems, `main: ${config.message(name, p)}: not copied, so the service serves no HTTPS`);
		if (p || sys.fs.stat(tls[name]) == null)
			usable = false;
	}

	if (!usable)
		tls = null;

	files = sort(uniq(files));
	groups = sort(uniq(groups));

	return {
		ubus: grant.merge(ubus),
		capabilities: sort(uniq(capabilities)),
		groups,
		groups_off: sort(uniq(filter(groups_off, (g) => !(g in groups)))),
		files,
		files_off: sort(uniq(filter(files_off, (p) => !(p in files)))),
		tls,
		port: svc.ok ? svc.data.listen_port : config.SERVICE_OPTIONS.listen_port.default,
		problems,
	};
};

/**
 * Makes the directories of `paths` that are not there, and their parents.
 *
 * @param {module:fs} fs
 * @param {string[]} paths
 * @returns {{ made: string[], problems: string[] }}
 */
export function make(fs, paths) {
	let made = [];
	let problems = [];

	for (let p in paths) {
		if (fs.stat(p) != null)
			continue;

		let dir = '';
		let failed = false;

		for (let part in split(substr(p, 1), '/')) {
			dir += '/' + part;
			if (fs.stat(dir) == null && !fs.mkdir(dir, 0755)) {
				push(problems, `cannot make ${dir}: ${fs.error() ?? 'unknown error'}`);
				failed = true;
				break;
			}
		}

		if (!failed)
			push(made, p);
	}

	return { made, problems };
};
