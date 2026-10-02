'use strict';

// Finds the installed collectors: every module in the collectors directory that
// exports a valid `meta` and a `collect`. One that does not load or is not valid
// is logged and left out, so a broken subpackage costs only its own collector.
// So is one that is not in strict mode, or imports anything but the collector
// API, which its text tells before it is loaded, and, given a probe
// (prometheus_exporter.probe's), one that does not load within its time.
//
// It is the facade of loader/: the modules there are its own, and what others
// take of them it exports.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { NEEDS } from 'prometheus_exporter.deps';
import * as jail from 'prometheus_exporter.jail';
import * as config from 'prometheus_exporter.config';
import * as scan from 'prometheus_exporter.loader.imports';

export const DIR = '/usr/share/ucode/prometheus_exporter/collectors';

const NAME = /^[a-z0-9][a-z0-9_-]*$/;
const OPTION_TYPES = [ 'bool', 'int', 'string' ];
const OPTION_KEYS = [ 'default', 'help', 'datatype' ];

// A collector's title, as a list or a form shows it.
export const TITLE_MAX = 40;

// The most seconds meta.timeout may give a collector's commands.
export const TIMEOUT_MAX = config.EXEC_TIMEOUT_MAX;

// The collectors of the exporter's own packages, by module: those of
// src/prometheus_exporter/collectors, as a test keeps it. A family one of
// them writes is its own in a scrape before any other collector's
// (prometheus_exporter.ownership): a collector of another package never takes
// one of theirs, whatever its name.
export const OWN = [
	'bmx7', 'chrony', 'conntrack', 'cpu', 'dawn', 'dhcp_leases', 'diskstats', 'dnsmasq', 'entropy', 'ethtool',
	'exporter', 'filefd', 'filesystem', 'hostapd_stations', 'hostapd_ubus_stations', 'hwmon', 'loadavg', 'ltq_dsl',
	'meminfo', 'modemmanager', 'mwan3', 'nat_traffic', 'netclass', 'netdev', 'netstat', 'nft_counters', 'openwrt',
	'openwrt_interfaces', 'qdisc', 'realtek_poe', 'selinux', 'snmp6', 'sockstat', 'softnet', 'textfile', 'thermal',
	'time', 'timesync', 'ubnt_manager', 'uci_dhcp_host', 'uname', 'unbound', 'vmstat', 'wifi', 'wireguard',
];

// What meta.cost takes: how much a run of the collector costs, roughly, before
// the ledger has timed it (prometheus_exporter.ledger's order).
export const COSTS = [ 'light', 'heavy' ];

// The module a collector's name lives in: a module name cannot hold '-'.
export function id_of(name) {
	return replace(name, '-', '_');
};

// A module's exports, by name. require() cannot load an ES module, but a
// script that imports one can.
export function import_module(id) {
	return loadstring(sprintf('import * as c from %J;\nreturn c;', 'prometheus_exporter.collectors.' + id),
		{ raw_mode: true })();
};

function invalid(id, msg) {
	return Result.err(errors.COLLECTOR_INVALID, `${id}: ${msg}`);
}

function is_strings(v) {
	return type(v) == 'array' && length(filter(v, (s) => type(s) != 'string' || s == '')) == 0;
}

// One of meta.options: { default, help, datatype }, the datatype one the core
// knows, that takes the default's type and the default itself.
function validate_option(id, key, spec) {
	if (!match(key, /^[a-z][a-z0-9_]*$/))
		return invalid(id, `option '${key}' needs a name of a-z, 0-9 and _`);
	if (type(spec) != 'object')
		return invalid(id, `option '${key}' must be { default, help, datatype }`);

	for (let k in keys(spec))
		if (!(k in OPTION_KEYS))
			return invalid(id, `option '${key}' has '${k}', not one of default, help, datatype`);

	if (!(type(spec.default) in OPTION_TYPES))
		return invalid(id, `option '${key}' needs a boolean, integer or string default`);
	if (type(spec.help) != 'string' || spec.help == '')
		return invalid(id, `option '${key}' needs a help sentence`);
	if (spec.datatype == null)
		return Result.ok();

	let dt = config.datatype(spec.datatype);

	if (!dt)
		return invalid(id, `option '${key}': unknown datatype ${sprintf('%J', spec.datatype)}`);
	if (!(type(spec.default) in dt.types))
		return invalid(id, `option '${key}': datatype ${spec.datatype} does not take a ${type(spec.default)}`);
	if (!dt.check(spec.default))
		return invalid(id, `option '${key}': its default is not ${dt.expected}`);

	return Result.ok();
}

// meta.paths: strings, whose {option}s name string options, that are mounts
// once filled with the defaults; { path: such a string, owned: true }, a
// directory the exporter makes when it is not there; or functions, whose
// paths the jail checks.
function validate_paths(id, meta) {
	if (type(meta.paths) != 'array' || !length(meta.paths))
		return invalid(id, 'meta.paths must list paths, or functions that give them');
	if (!length(filter(meta.needs, (n) => n in [ 'fs', 'socket', 'exec' ])))
		return invalid(id, 'meta.paths without fs, socket or exec in meta.needs');

	for (let p in meta.paths) {
		if (type(p) == 'function')
			continue;

		if (type(p) == 'object') {
			if (length(p) != 2 || type(p.path) != 'string' || p.owned !== true)
				return invalid(id, 'meta.paths: an owned path is { path, owned: true }');
			p = p.path;
		}

		if (type(p) != 'string')
			return invalid(id, 'meta.paths must list paths, or functions that give them');

		for (let name in jail.placeholders(p))
			if (type(meta.options?.[name]?.default) != 'string')
				return invalid(id, `meta.paths: {${name}} is not a string option`);

		let why = jail.path_problem(jail.fill(p, config.defaults(meta.options)));
		if (why)
			return invalid(id, `meta.paths: ${why}`);
	}

	return Result.ok();
}

// { id, meta, collect } for a module's exports, or COLLECTOR_INVALID.
export function validate(id, mod) {
	let meta = mod?.meta;

	if (type(meta) != 'object')
		return invalid(id, 'exports no meta');
	if (type(meta.name) != 'string' || !match(meta.name, NAME) || id_of(meta.name) != id)
		return invalid(id, `meta.name must be '${id}', or it with '-' for '_'`);
	if (type(meta.title) != 'string' || meta.title == '' || length(meta.title) > TITLE_MAX || match(meta.title, /[[:cntrl:]]/))
		return invalid(id, `meta.title must be a label of 1 to ${TITLE_MAX} characters`);
	if (type(meta.help) != 'string' || meta.help == '')
		return invalid(id, 'meta.help must be a sentence');
	if (!is_strings(meta.needs) || length(uniq(meta.needs)) != length(meta.needs))
		return invalid(id, 'meta.needs must list capabilities once each');

	for (let need in meta.needs)
		if (!(need in NEEDS))
			return invalid(id, `unknown need '${need}'`);

	if ('uci' in meta.needs) {
		if (!is_strings(meta.configs) || !length(meta.configs))
			return invalid(id, 'meta.configs must list the uci configs it reads');
		for (let c in meta.configs)
			if (!match(c, /^[a-z0-9_-]+$/) || c == config.NAME)
				return invalid(id, `meta.configs cannot name '${c}'; its own options come as options`);
	} else if (meta.configs != null) {
		return invalid(id, 'meta.configs without uci in meta.needs');
	}

	if ('exec' in meta.needs) {
		if (!is_strings(meta.commands) || !length(meta.commands))
			return invalid(id, 'meta.commands must list the programs exec runs');
	} else if (meta.commands != null) {
		return invalid(id, 'meta.commands without exec in meta.needs');
	}

	// The commands it runs only where they are installed (timesync's
	// chronyc, where chrony is the NTP daemon): no package it depends on
	// has them, and the jail does without them.
	if (meta.optional_commands != null)
		if (!is_strings(meta.optional_commands) || length(filter(meta.optional_commands, (c) => !(c in (meta.commands ?? [])))))
			return invalid(id, 'meta.optional_commands must list some of meta.commands');

	if (meta.timeout != null) {
		if (!('exec' in meta.needs))
			return invalid(id, 'meta.timeout without exec in meta.needs');
		if (type(meta.timeout) != 'int' || meta.timeout < 1 || meta.timeout > TIMEOUT_MAX)
			return invalid(id, `meta.timeout must be the seconds its commands may take, 1 to ${TIMEOUT_MAX}`);
	}

	if (meta.max_samples != null)
		if (type(meta.max_samples) != 'int' || meta.max_samples < 1 || meta.max_samples > config.MAX_SAMPLES_MAX)
			return invalid(id, `meta.max_samples must be the samples it may write, 1 to ${config.MAX_SAMPLES_MAX}`);

	if (meta.cost != null && !(meta.cost in COSTS))
		return invalid(id, `meta.cost must be one of ${join(', ', COSTS)}`);

	if (meta.options != null && type(meta.options) != 'object')
		return invalid(id, 'meta.options must be an object of { default, help, datatype }');

	if ('enabled' in keys(meta.options ?? {}))
		return invalid(id, "option 'enabled' is the core's, every collector has it");
	if ('timeout' in keys(meta.options ?? {}))
		return invalid(id, "option 'timeout' is the core's, every collector that runs programs has it; meta.timeout sets its default");
	if ('budget' in keys(meta.options ?? {}))
		return invalid(id, "option 'budget' is the core's, every collector has it");
	if ('max_samples' in keys(meta.options ?? {}))
		return invalid(id, "option 'max_samples' is the core's, every collector has it; meta.max_samples sets its default");

	for (let key, spec in meta.options) {
		let res = validate_option(id, key, spec);
		if (!res.ok)
			return res;
	}

	if (meta.paths != null) {
		let res = validate_paths(id, meta);
		if (!res.ok)
			return res;
	}

	if (type(mod.collect) != 'function')
		return invalid(id, 'exports no collect function');

	return Result.ok({ id, meta: { options: {}, ...meta }, collect: mod.collect });
};

// The module names in `dir`, sorted.
export function discover(fs, dir) {
	let files = filter(fs.lsdir(dir) ?? [], (f) => match(f, /^[a-z0-9_]+\.uc$/));

	return sort(map(files, (f) => substr(f, 0, -3)));
};

// What comes before a module's first statement: blank space, comments, and a
// first line that starts with #! (as ucode skips it).
const LEADING = /^(\s+|\/\/[^\n]*|\/\*([^*]|\*+[^*\/])*\*+\/)/;
const DIRECTIVES = [ "'use strict'", '"use strict"' ];

// LEADING's match at the start of `text`. musl's regexec reads the whole text
// for it, a module of 10 kB for a comment of a line: so it reads a window,
// and the whole text only when what it found, or a block comment it did not
// find the end of, may go on past the window.
const WINDOW = 1024;

function leading(text) {
	if (length(text) <= WINDOW)
		return match(text, LEADING);

	let w = substr(text, 0, WINDOW);
	let m = match(w, LEADING);

	if ((m && length(m[0]) == WINDOW) || (!m && substr(w, 0, 2) == '/*'))
		return match(text, LEADING);

	return m;
}

// Whether the text of a module is in strict mode: its first statement is the
// 'use strict' directive. ucode honours the directive there alone, after only
// what LEADING skips: anywhere else it is a string that does nothing. Strict
// mode makes a variable that was never declared an error rather than a
// global that every later collector of the scrape would see.
export function is_strict(text) {
	if (type(text) != 'string')
		return false;

	if (substr(text, 0, 2) == '#!') {
		let nl = index(text, '\n');
		text = (nl < 0) ? '' : substr(text, nl);
	}

	for (let m = leading(text); m; m = leading(text))
		text = substr(text, length(m[0]));

	if (!(substr(text, 0, 12) in DIRECTIVES))
		return false;

	// The directive is a statement of its own: a ';' or the end of its line.
	let rest = ltrim(substr(text, 12), ' \t\r');

	return rest == '' || substr(rest, 0, 1) in [ ';', '\n' ];
};

// The one module a collector imports: the collector API.
export const API = 'prometheus_exporter.api';

// What a module's text imports and loads, without compiling it
// (prometheus_exporter.loader.imports).
export const imports = scan.imports;

// The capabilities a collector reaches the system through, by the module it
// would import for it instead: [ need, what it does with it ].
const CAPABILITIES = {
	fs: [ 'fs', 'reads files' ],
	ubus: [ 'ubus', 'calls ubus' ],
	uci: [ 'uci', 'reads uci configs' ],
	rtnl: [ 'rtnl', 'asks rtnetlink' ],
	nl80211: [ 'nl80211', 'asks nl80211' ],
	socket: [ 'socket', 'talks to a Unix socket' ],
};

// The modules of the core the API exports a part of, by the name it has there.
const PARTS = {
	'prometheus_exporter.result': 'Result',
	'prometheus_exporter.errors': 'errors',
	'prometheus_exporter.services': 'services',
	'prometheus_exporter.proc': 'proc',
	'prometheus_exporter.exposition': 'exposition',
};

// What a collector does instead of loading `module` (null when it is not a
// string literal).
function instead(module) {
	let cap = CAPABILITIES[module];

	if (cap)
		return `a collector ${cap[1]} through deps.${cap[0]}, with '${cap[0]}' in meta.needs`;
	if (PARTS[module])
		return `take ${PARTS[module]} from ${API}`;

	return `a collector imports ${API} alone`;
}

// Why a collector module's text loads what a collector may not, or null: it
// imports a module other than the collector API, or calls require, loadfile
// or loadstring, which load code past its imports. A collector takes the
// system through the capabilities collect() gets in deps, and what it uses of
// the exporter from the API. The loader logs the same text, `collector check`
// fails with it, and the tests hold our collectors to it.
export function import_problem(text) {
	let found = imports(text);
	let problems = [];

	for (let i in found.imports)
		if (i.module != API)
			push(problems, `imports ${i.module} (line ${i.line}): ${instead(i.module)}`);

	for (let l in found.loads)
		push(problems, `calls ${l.fn}(${l.module != null ? sprintf('%J', l.module) : ''}) (line ${l.line}): ${instead(l.module)}`);

	return length(problems) ? join('; ', problems) : null;
};

// Why the loader leaves a module out by its text alone, before it loads it,
// or null: it is not in strict mode (is_strict), or it loads what a collector
// may not (import_problem).
export function refusal(text) {
	if (!is_strict(text))
		return "not in strict mode: its first statement must be 'use strict'";

	return import_problem(text);
};

// The valid collectors in `dir`, sorted by name; log(level, msg) takes, at err,
// each that is left out and why. A module must be in strict mode and import
// the collector API alone (refusal), which its text tells before it is
// loaded. probe(ids), when given, loads them elsewhere first
// (prometheus_exporter.probe): { <id>: { ok, error, hung } }, and only those
// that loaded there are loaded here.
export function load(fs, dir, import_fn, log, probe) {
	let collectors = [];
	let ids = [];

	for (let id in discover(fs, dir)) {
		let why = refusal(fs.readfile(`${dir}/${id}.uc`));

		if (why == null)
			push(ids, id);
		else
			log('err', `skipping collector: ${Result.describe(invalid(id, why))}`);
	}

	let probed = probe ? probe(ids) : {};

	for (let id in ids) {
		let p = probed[id];
		let mod;

		if (p?.hung) {
			log('err', `collector '${id}' hung at load: ${p.error}; it is left out`);
			continue;
		}

		if (p != null && !p.ok) {
			log('err', `cannot load collector '${id}': ${p.error}`);
			continue;
		}

		try {
			mod = import_fn(id);
		} catch (e) {
			log('err', `cannot load collector '${id}': ${split(e.message, '\n')[0]}`);
			continue;
		}

		let res = validate(id, mod);
		if (!res.ok) {
			log('err', `skipping collector: ${Result.describe(res)}`);
			continue;
		}

		push(collectors, res.data);
	}

	return sort(collectors, (a, b) => a.meta.name < b.meta.name ? -1 : 1);
};
