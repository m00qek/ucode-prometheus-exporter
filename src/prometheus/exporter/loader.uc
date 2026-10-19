/**
 * Finds the installed collectors: each module there that exports a valid `meta` and `collect`.
 *
 * @module prometheus_exporter_loader
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import { NEEDS } from 'prometheus.exporter.deps';
import * as jail from 'prometheus.exporter.jail';
import * as privileges from 'prometheus.exporter.privileges';
import * as config from 'prometheus.exporter.config';
import * as scan from 'prometheus.exporter.loader.imports';
import * as purity from 'prometheus.exporter.loader.purity';
import * as collection from 'prometheus.exporter.collection';

/**
 * A collector as the loader takes it (validate's).
 *
 * @typedef {{ id: string, meta: Meta, collect: Collect, own: boolean }} Collector
 */

/**
 * The installed collectors' directory.
 *
 * @type {string}
 */
export const DIR = collection.DIR;

const NAME = /^[a-z0-9][a-z0-9_-]*$/;
const OPTION_TYPES = [ 'bool', 'int', 'string' ];
const OPTION_KEYS = [ 'default', 'title', 'help', 'datatype' ];

/**
 * The most characters of a collector's title and of an option's.
 *
 * @type {int}
 */
export const TITLE_MAX = 40;

/**
 * The most seconds meta.timeout may give a collector's commands.
 *
 * @type {int}
 */
export const TIMEOUT_MAX = config.EXEC_TIMEOUT_MAX;

/**
 * The collectors of the exporter's own packages, by module.
 *
 * @type {string[]}
 */
export const OWN = [
	'bmx7', 'chrony', 'conntrack', 'cpu', 'dawn', 'dhcp_leases', 'diskstats', 'dnsmasq', 'entropy', 'ethtool',
	'exporter', 'filefd', 'filesystem', 'hostapd_stations', 'hostapd_ubus_stations', 'hwmon', 'interrupts', 'loadavg', 'ltq_dsl',
	'meminfo', 'modemmanager', 'mwan3', 'nat_traffic', 'netclass', 'netdev', 'netstat', 'nft_counters', 'openwrt',
	'openwrt_interfaces', 'pressure', 'qdisc', 'realtek_poe', 'selinux', 'snmp6', 'sockstat', 'softnet', 'textfile', 'thermal',
	'time', 'timesync', 'ubnt_manager', 'uci_dhcp_host', 'uname', 'unbound', 'vmstat', 'wifi', 'wireguard',
];

/**
 * What meta.cost takes: how much a run costs, roughly, before the ledger has timed it.
 *
 * @type {string[]}
 */
export const COSTS = [ 'light', 'heavy' ];

export const id_of = collection.id_of;
export const import_module = collection.import_module;
export const import_modules = collection.import_modules;

function invalid(id, msg) {
	return Result.err(errors.COLLECTOR_INVALID, `${id}: ${msg}`);
}

function is_strings(v) {
	return type(v) == 'array' && length(filter(v, (s) => type(s) != 'string' || s == '')) == 0;
}

function is_title(v) {
	return type(v) == 'string' && v != '' && length(v) <= TITLE_MAX && !match(v, /[[:cntrl:]]/);
}

function validate_option(id, key, spec) {
	if (!match(key, /^[a-z][a-z0-9_]*$/))
		return invalid(id, `option '${key}' needs a name of a-z, 0-9 and _`);
	if (type(spec) != 'object')
		return invalid(id, `option '${key}' must be { default, title, help, datatype }`);

	for (let k in keys(spec))
		if (!(k in OPTION_KEYS))
			return invalid(id, `option '${key}' has '${k}', not one of default, title, help, datatype`);

	if (!(type(spec.default) in OPTION_TYPES))
		return invalid(id, `option '${key}' needs a boolean, integer or string default`);
	if (!is_title(spec.title))
		return invalid(id, `option '${key}' needs a title of 1 to ${TITLE_MAX} characters`);
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

/**
 * { id, meta, collect } for a module's exports, or COLLECTOR_INVALID.
 *
 * @param {string} id the module's name.
 * @param {?CollectorModule} mod its exports, as import_module gives them.
 * @returns {Result<Collector>} the collector, or COLLECTOR_INVALID saying what is wrong.
 */
export function validate(id, mod) {
	let meta = mod?.meta;

	if (type(meta) != 'object')
		return invalid(id, 'exports no meta');
	if (type(meta.name) != 'string' || !match(meta.name, NAME) || id_of(meta.name) != id)
		return invalid(id, `meta.name must be '${id}', or it with '-' for '_'`);
	if (!is_title(meta.title))
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
		return invalid(id, 'meta.options must be an object of { default, title, help, datatype }');

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

	let why = privileges.meta_problem(meta);
	if (why)
		return invalid(id, why);

	if (type(mod.collect) != 'function')
		return invalid(id, 'exports no collect function');

	return Result.ok({ id, meta: { options: {}, ...meta }, collect: mod.collect, own: id in OWN });
};

export const discover = collection.discover;

const LEADING = /^(\s+|\/\/[^\n]*|\/\*([^*]|\*+[^*\/])*\*+\/)/;
const DIRECTIVES = [ "'use strict'", '"use strict"' ];

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

/**
 * Whether a module's text is in strict mode: its first statement is 'use strict'.
 *
 * @param {*} text the module's text; anything but a string is not.
 * @returns {boolean} whether its first statement is 'use strict'.
 */
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

	let rest = ltrim(substr(text, 12), ' \t\r');

	return rest == '' || substr(rest, 0, 1) in [ ';', '\n' ];
};

/**
 * The one module a collector imports: the collector API.
 *
 * @type {string}
 */
export const API = 'prometheus.exporter';

export const imports = scan.imports;

const CAPABILITIES = {
	fs: [ 'fs', 'reads files' ],
	ubus: [ 'ubus', 'calls ubus' ],
	uci: [ 'uci', 'reads uci configs' ],
	rtnl: [ 'rtnl', 'asks rtnetlink' ],
	nl80211: [ 'nl80211', 'asks nl80211' ],
	socket: [ 'socket', 'talks to a Unix socket or a TCP port of the device' ],
};

const PARTS = {
	'prometheus.exporter.result': 'Result',
	'prometheus.exporter.errors': 'errors',
	'prometheus.exporter.services': 'services',
	'prometheus.exporter.proc': 'proc',
	'prometheus.exporter.exposition': 'exposition',
};

function instead(module) {
	let cap = CAPABILITIES[module];

	if (cap)
		return `a collector ${cap[1]} through deps.${cap[0]}, with '${cap[0]}' in meta.needs`;
	if (PARTS[module])
		return `take ${PARTS[module]} from ${API}`;

	return `a collector imports ${API} alone`;
}

const INSTEAD_OF_SYSTEM = "a collector runs programs through deps.exec, with 'exec' in meta.needs and the program in meta.commands, which kills one still running at its timeout";

/**
 * Why a collector module's text loads what a collector may not, or null.
 *
 * @param {string} text the collector module's text.
 * @returns {?string} the problems, joined by '; ', or null.
 */
export function import_problem(text) {
	let found = imports(text);
	let problems = [];

	for (let i in found.imports)
		if (i.module != API)
			push(problems, `imports ${i.module} (line ${i.line}): ${instead(i.module)}`);

	for (let l in found.loads)
		push(problems, `calls ${l.fn}(${l.module != null ? sprintf('%J', l.module) : ''}) (line ${l.line}): ${(l.fn == 'system') ? INSTEAD_OF_SYSTEM : instead(l.module)}`);

	return length(problems) ? join('; ', problems) : null;
};

/**
 * Why a collector module's text does more at its top level than declare, or null.
 *
 * @param {string} text the collector module's text.
 * @returns {?string} the problems, joined by '; ', or null.
 */
export function purity_problem(text) {
	return purity.problem(text, API);
};

/**
 * Why the loader leaves a module out by its text alone, before it loads it, or null.
 *
 * @param {?string} text the module's text, null when it cannot be read.
 * @returns {?string} why, or null.
 */
export function refusal(text) {
	if (!is_strict(text))
		return "not in strict mode: its first statement must be 'use strict'";

	return import_problem(text);
};

function admitted(fs, dir, log) {
	let ids = [];

	for (let id in discover(fs, dir)) {
		let why = refusal(fs.readfile(`${dir}/${id}.uc`));

		if (why == null)
			push(ids, id);
		else
			log('err', `skipping collector: ${Result.describe(invalid(id, why))}`);
	}

	return ids;
}

function probed_ok(id, p, log) {
	let why = collection.left_out(id, p);

	if (why != null)
		log('err', why);

	return why == null;
}

/**
 * What a child process of the probe reports of module `id` of `dir`, checked as load() does.
 *
 * @param {module:fs} fs what reads the module: an object of fs's readfile.
 * @param {string} dir the collectors' directory (DIR).
 * @param {string} id the module's name.
 * @param {function(string): CollectorModule} import_fn what loads it.
 * @returns {{ meta: ?string, own: ?boolean, invalid: ?string }} the report.
 */
export function check_module(fs, dir, id, import_fn) {
	let why = refusal(fs.readfile(`${dir}/${id}.uc`));

	if (why != null)
		return { invalid: Result.describe(invalid(id, why)) };

	let res = validate(id, import_fn(id));

	return res.ok ? { meta: collection.fingerprint(res.data.meta), own: res.data.own } : { invalid: Result.describe(res) };
};

/**
 * The valid collectors in `dir`, sorted by name; each left out is logged at err.
 *
 * @param {module:fs} fs what reads the directory: an object of fs's lsdir and readfile.
 * @param {string} dir the collectors' directory (DIR).
 * @param {function(string): CollectorModule} import_fn import_module, or a test's.
 * @param {Log} log the exporter's log.
 * @param {?function(string[]): Object<string, ProbeOutcome>} probe loads them in a child first.
 * @param {?function(string[]): Object<string, CollectorModule>} import_all import_modules, or null.
 * @returns {Collector[]} the valid collectors, sorted by name.
 */
export function load(fs, dir, import_fn, log, probe, import_all) {
	let collectors = [];
	let ids = admitted(fs, dir, log);
	let probed = probe ? probe(ids) : {};
	let ready = filter(ids, (id) => probed[id] == null || probed[id].ok);
	let together = null;

	if (import_all && length(ready)) {
		try {
			together = import_all(ready);
		} catch (e) {
			log('notice', `cannot load the collectors as one program, so each is loaded alone: ${split(e.message, '\n')[0]}`);
		}
	}

	for (let id in ids) {
		let mod;

		if (!probed_ok(id, probed[id], log))
			continue;

		try {
			mod = (together != null) ? together[id] : import_fn(id);
		} catch (e) {
			log('err', collection.load_error(id, split(e.message, '\n')[0]));
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
