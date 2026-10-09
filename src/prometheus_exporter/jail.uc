/**
 * What procd's jail mounts for the exporter: what its installed and enabled
 * collectors declare they need from the filesystem, and nothing more. procfs,
 * sysfs and /dev/log come with the jail's options, and the exporter's code
 * and libraries with its own mounts (SERVICE), which jail.uc prints for the
 * init script along with the collectors'. The ubus socket comes with the
 * jail's ubus option, which the init script gives only when an enabled
 * collector needs ubus: the jail's mounts (mounts()) then name the socket
 * (UBUS_SOCKET), and the init script takes it for the option.
 *
 * A collector gets /etc/config/<c> for each of its meta.configs, the paths of
 * meta.paths, and with exec, /bin/sh (popen's
 * shell) and each of its commands as found on PATH; a command missing there
 * is a problem, unless it is one of meta.optional_commands. ujail mounts a
 * binary's shared libraries along with it. It cannot mount a socket itself
 * (it opens what it mounts), so a collector declares a socket's directory.
 *
 * A path of meta.paths that is not there is left out of the mounts (ujail
 * would leave it out too), and is `missing`: once it is there, the mounts
 * differ, and a reload restarts the exporter with it. The init script runs a
 * watcher while a path is missing (unbound's socket directory, which unbound
 * makes when it starts, after the exporter at boot), which asks for that reload.
 *
 * A path declared { path, owned: true } is the exporter's own: a directory no
 * other service makes (textfile's), which the init script makes, before it
 * mounts it, when it is not there (make()). Never another service's: it
 * must be under one of config.OWNED_ROOTS, or it is a problem, and neither
 * made nor mounted.
 *
 * sys: { uci: a uci cursor, fs: { stat }, path: the PATH commands are found on }
 *
 * @module prometheus_exporter_jail
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as privileges from 'prometheus_exporter.privileges';
import * as grant from 'prometheus_exporter.grant';
import { uci_handles } from 'prometheus_exporter.deps';
import { DIR as STATE_DIR } from 'prometheus_exporter.state';

/**
 * What the jail's functions take of the system, as the module's top comment
 * says: a uci cursor, fs (its stat; jailed's also glob, readfile and popen)
 * and the PATH commands are found on (PATH when null).
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

/**
 * Where uci's configs are.
 *
 * @type {string}
 */
export const CONFIG_DIR = '/etc/config';

/**
 * The exporter's own config, which every jail has.
 *
 * @type {string}
 */
export const OWN_CONFIG = `${CONFIG_DIR}/${config.NAME}`;

/**
 * popen's shell, which a collector that runs programs gets.
 *
 * @type {string}
 */
export const SHELL = '/bin/sh';

/**
 * The ubus socket, which procd's jail option `ubus` mounts: the jail's
 * mounts name it while an enabled collector needs ubus, and the init script
 * gives the jail that option, and no mount of its own, for it.
 *
 * @type {string}
 */
export const UBUS_SOCKET = '/var/run/ubus/ubus.sock';

/**
 * The service's own read-only mounts, which every instance has: uhttpd's
 * ucode plugin, the libraries ucode's modules load (zlib's, for gzip), ucode's
 * modules, the exporter's code, its handler, and ash, for its kill: a scrape
 * kills the child process a scrape that died left running a collector
 * (prometheus_exporter.progress's bury). jail.uc prints them for the init
 * script, before the collectors' mounts; a path that ends in '*' is a glob,
 * which the init script's shell expands.
 *
 * @type {string[]}
 */
export const SERVICE = [
	'/usr/lib/uhttpd_ucode.so', '/lib/libubus.so*', '/lib/libuci.so*', '/usr/lib/libnl*.so*', '/usr/lib/libz.so*',
	'/usr/lib/ucode', '/usr/share/ucode/prometheus_exporter', `/usr/libexec/${config.NAME}/handler.uc`, SHELL,
];

/**
 * What procd's jail options give every instance (procfs, sysfs and the
 * log's socket) and ujail itself (its devices and resolv.conf).
 *
 * @type {string[]}
 */
export const GIVEN = [
	'/proc', '/sys', '/dev/log',
	'/dev/null', '/dev/zero', '/dev/full', '/dev/random', '/dev/urandom', '/etc/resolv.conf',
];

/**
 * What every jail of the service has, whatever its collectors declare: what
 * the jail gives (GIVEN), the service's own mounts (SERVICE), the exporter's
 * config and its state, which the init script mounts read-write. Nothing
 * else is there but what the enabled collectors declare: a collector reads
 * these without declaring them, though only procfs and sysfs are meant for
 * it. prometheus_exporter.devkit.collector runs a collector's tests in a filesystem of these and
 * its own mounts, and a test holds the init script to them.
 *
 * @type {string[]}
 */
export const COMMON = [ ...GIVEN, ...SERVICE, OWN_CONFIG, STATE_DIR ];

/**
 * procd's PATH, which the jailed uhttpd and so popen's shell have.
 *
 * @type {string}
 */
export const PATH = '/usr/sbin:/usr/bin:/sbin:/bin';

/**
 * Directories that hold what belongs to every service: never mounted whole for
 * one collector.
 *
 * @type {string[]}
 */
export const BROAD = [
	'/', '/bin', '/dev', '/etc', '/etc/config', '/lib', '/proc', '/run', '/sbin', '/sys', '/tmp', '/tmp/run',
	'/usr', '/usr/bin', '/usr/lib', '/usr/sbin', '/usr/share', '/var', '/var/run',
];

// `{option}` in a path of meta.paths: the value of a string option.
const PLACEHOLDER = /\{([a-z][a-z0-9_]*)\}/g;

/**
 * Why `path` cannot be a mount, or null. The init script hands procd the mounts
 * unquoted, so a space or a glob character would be read as the shell does.
 *
 * @param {*} path the path; anything but an absolute path string is a problem.
 * @returns {?string} why, or null.
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
 * Why the exporter cannot make and mount `path` as its own, or null: it is
 * a plain path (path_problem) under one of config.OWNED_ROOTS.
 *
 * @param {*} path the path; anything but an absolute path string is a problem.
 * @returns {?string} why, or null.
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
 * @param {string} template a path of meta.paths.
 * @returns {string[]} the names, in order.
 */
export function placeholders(template) {
	return map(match(template, PLACEHOLDER) ?? [], (m) => m[1]);
};

/**
 * A path of meta.paths with its {option}s filled in, or null when one of them
 * is not a string.
 *
 * @param {string} template a path of meta.paths.
 * @param {?Object} options the collector's options, typed.
 * @returns {?string} the path.
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
 * @param {module:fs} fs what looks: an object of fs's stat.
 * @param {string} search a PATH: directories, separated by ':'.
 * @param {string} cmd the command: a name, or a path when it holds a '/'.
 * @returns {?string} the command's path.
 */
export function which(fs, search, cmd) {
	if (index(cmd, '/') >= 0)
		return fs.stat(cmd)?.type == 'file' ? cmd : null;

	for (let dir in split(search, ':'))
		if (dir != '' && fs.stat(`${dir}/${cmd}`)?.type == 'file')
			return `${dir}/${cmd}`;

	return null;
};

// One function of meta.paths: what it gives, or why it gave nothing.
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
 * { paths, owned, problems } of meta.paths for these typed options and uci
 * handles; `owned` are the paths declared { path, owned: true }.
 *
 * @param {Meta} meta the collector's meta.
 * @param {Object} options its options, typed.
 * @param {Object<string, UciHandle>} handles uci handles over its configs.
 * @returns {{ paths: string[], owned: string[], problems: string[] }} the
 *   paths, sorted and once each, the owned ones, and what went wrong.
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
			// An option's directory may end in '/', as datatype directory
			// takes it and the collector reads it: the same directory.
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
 * What one collector gets in the jail: { enabled, options (a Result), configs,
 * paths, owned, commands ({ name: path or null }), mounts, problems, missing },
 * and what its user may do there (prometheus_exporter.privileges): ubus, the
 * calls it declares for its options, capabilities, groups and proc_files.
 * `missing` are the paths not there now, which the mounts leave out; not the
 * owned ones, which the service makes before it mounts them.
 *
 * @param {Collector} c the collector.
 * @param {JailSys} sys the system.
 * @returns {CollectorJail} what it gets.
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

	// Its ubus calls for its options; with options not valid, which keep it
	// from running, for none.
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
 * { mounts, problems, missing, owned } of the jail for these installed
 * collectors: the exporter's config, what each enabled one gets, and the ubus
 * socket when one of them needs ubus, sorted and once each; the paths of the enabled ones that are not there, and those the
 * exporter makes. A problem names its collector.
 *
 * @param {Collector[]} collectors the installed collectors.
 * @param {JailSys} sys the system.
 * @returns {{ mounts: string[], problems: string[], missing: string[], owned: string[] }}
 *   the jail's.
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
 * What the service's user may do in the jail of these installed collectors,
 * for prometheus_exporter.grant's make(): the ubus calls, capabilities,
 * groups and proc files of the enabled ones, read access to the configs the
 * jail mounts (the exporter's own among them), the TLS files when both are
 * there, and the port it listens on; and what to take back, the groups and
 * files of the installed collectors that are not enabled, that no enabled
 * one has too. A problem names its collector.
 *
 * @param {Collector[]} collectors the installed collectors.
 * @param {JailSys} sys the system.
 * @returns {Grants} what to grant.
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
	let tls = (cert != '' && key != '' && sys.fs.stat(cert) != null && sys.fs.stat(key) != null) ? { cert, key } : null;

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
 * Makes the directories of `paths` that are not there, and their parents:
 * { made: [ path ], problems: [ why ] }. fs: { stat, mkdir, error }.
 *
 * @param {module:fs} fs the fs module, or an object of its stat, mkdir and
 *   error.
 * @param {string[]} paths the directories.
 * @returns {{ made: string[], problems: string[] }} what it made, and why it
 *   could not.
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
