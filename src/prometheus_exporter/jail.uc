'use strict';

// What procd's jail mounts for the exporter: what its installed and enabled
// collectors declare they need from the filesystem, and nothing more. procfs,
// sysfs, /dev/log and the ubus socket come with the jail's options, and the
// exporter's code and libraries with the init script's own mounts.
//
// A collector gets /etc/config/<c> for each of its meta.configs, the paths of
// meta.paths, and with exec, /bin/sh (popen's shell) and each of its commands
// as found on PATH; a command missing there is a problem, unless it is one of
// meta.optional_commands. ujail mounts a binary's shared libraries along with
// it. It cannot mount a socket itself (it opens what it mounts), so a
// collector declares a socket's directory.
//
// A path of meta.paths that is not there is left out of the mounts (ujail
// would leave it out too), and is `missing`: once it is there, the mounts
// differ, and a reload restarts the exporter with it. The init script runs a
// watcher while a path is missing (unbound's socket directory, which unbound
// makes when it starts, after the exporter at boot), which asks for that reload.
//
// A path declared { path, owned: true } is the exporter's own: a directory no
// other service makes (textfile's), which the init script makes, before it
// mounts it, when it is not there (make()). Never another service's.
//
// sys: { uci: a uci cursor, fs: { stat }, path: the PATH commands are found on }

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import { uci_handles } from 'prometheus_exporter.deps';

export const CONFIG_DIR = '/etc/config';
export const OWN_CONFIG = `${CONFIG_DIR}/${config.NAME}`;
export const SHELL = '/bin/sh';

// procd's PATH, which the jailed uhttpd and so popen's shell have.
export const PATH = '/usr/sbin:/usr/bin:/sbin:/bin';

// Directories that hold what belongs to every service: never mounted whole for
// one collector.
export const BROAD = [
	'/', '/bin', '/dev', '/etc', '/etc/config', '/lib', '/proc', '/run', '/sbin', '/sys', '/tmp', '/tmp/run',
	'/usr', '/usr/bin', '/usr/lib', '/usr/sbin', '/usr/share', '/var', '/var/run',
];

// `{option}` in a path of meta.paths: the value of a string option.
const PLACEHOLDER = /\{([a-z][a-z0-9_]*)\}/g;

// Why `p` cannot be a mount, or null. The init script hands procd the mounts
// unquoted, so a space or a glob character would be read as the shell does.
export function path_problem(p) {
	if (type(p) != 'string' || substr(p, 0, 1) != '/')
		return `${sprintf('%J', p)} is not an absolute path`;
	if (match(p, /[[:space:][:cntrl:]*?[]/))
		return `${sprintf('%J', p)} holds a space, a control or a glob character`;
	if (p != '/' && (match(p, /\/\/|\/\.\.?(\/|$)/) || substr(p, -1) == '/'))
		return `${p} is not a plain path (no //, . or .., nor a trailing /)`;
	if (p in BROAD)
		return `${p} is too broad to mount for one collector`;

	return null;
};

// The option names a path of meta.paths holds as {name}.
export function placeholders(template) {
	return map(match(template, PLACEHOLDER) ?? [], (m) => m[1]);
};

// A path of meta.paths with its {option}s filled in, or null when one of them
// is not a string.
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

// Where the shell finds `cmd` on `search` (a PATH), or null.
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

// { paths, owned, problems } of meta.paths for these typed options and uci
// handles; `owned` are the paths declared { path, owned: true }.
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
			let why = path_problem(p);

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

// What one collector gets in the jail: { enabled, options (a Result), configs,
// paths, owned, commands ({ name: path or null }), mounts, problems, missing }.
// `missing` are the paths not there now, which the mounts leave out; not the
// owned ones, which the service makes before it mounts them.
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
	};
};

// { mounts, problems, missing, owned } of the jail for these installed
// collectors: the exporter's config, and what each enabled one gets, sorted and
// once each; the paths of the enabled ones that are not there, and those the
// exporter makes. A problem names its collector.
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
		push(missing, ...j.missing);
		push(owned, ...j.owned);
		for (let p in j.problems)
			push(problems, `${c.meta.name}: ${p}`);
	}

	return { mounts: sort(uniq(all)), problems, missing: sort(uniq(missing)), owned: sort(uniq(owned)) };
};

// Makes the directories of `paths` that are not there, and their parents:
// { made: [ path ], problems: [ why ] }. fs: { stat, mkdir, error }.
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
