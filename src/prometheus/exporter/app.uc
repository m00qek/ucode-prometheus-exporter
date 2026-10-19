/**
 * The exporter on the real system; the uhttpd handler and the command line both start here.
 *
 * @module prometheus_exporter_app
 */

'use strict';

import * as exposition from 'prometheus.exporter.exposition';
import * as deps from 'prometheus.exporter.deps';
import * as collection from 'prometheus.exporter.collection';
import * as scrape from 'prometheus.exporter.scrape';
import * as config from 'prometheus.exporter.config';
import * as http from 'prometheus.exporter.http';
import * as state from 'prometheus.exporter.state';
import * as deadline from 'prometheus.exporter.deadline';
import * as ledger from 'prometheus.exporter.ledger';
import * as runner from 'prometheus.exporter.runner';
import { probe as probe_modules } from 'prometheus.exporter.probe';
import { version } from 'prometheus.exporter.version';

/**
 * The exporter, as create() gives it.
 *
 * @typedef {{
 *   collectors: () => Collector[],
 *   scrape: (query_string: ?string, opts: ?ScrapeOptions) => ScrapeReply,
 *   mods: Modules
 * }} App
 */

/**
 * Basic auth that denies every request, as load_auth gives it.
 *
 * @typedef {{ broken: boolean, missing: ?boolean, unloaded: ?string }} BrokenAuth
 */

/**
 * The exporter as uhttpd's handler, as handler() gives it.
 *
 * @typedef {{
 *   collectors: () => Collector[],
 *   auth: ?(BasicAuth|BrokenAuth),
 *   natives: string[],
 *   compress: boolean,
 *   scrape_timeout: int,
 *   handle: (req: Object) => HttpReply
 * }} Handler
 */

/**
 * uhttpd's config file of basic auth, which the init script writes.
 *
 * @type {string}
 */
export const AUTH_FILE = `${state.RUN_DIR}/uhttpd.conf`;

/**
 * The program that loads basic auth's module, compiled the first time it is needed.
 *
 * @type {string}
 */
export const AUTH_PROGRAM = "import * as auth from 'prometheus.exporter.auth';\nreturn auth;";

let auth_loaded = null;

function auth_module(source) {
	if (source == null && auth_loaded != null)
		return { module: auth_loaded };

	let mod;

	try {
		mod = loadstring(source ?? AUTH_PROGRAM, { raw_mode: true })();
	} catch (e) {
		return { error: split(e.message, '\n')[0] };
	}

	if (type(mod?.parse_conf) != 'function' || type(mod.allowed) != 'function' ||
	    type(mod.REALM) != 'string' || type(mod.PATH) != 'string')
		return { error: 'it is not prometheus.exporter.auth' };

	if (source == null)
		auth_loaded = mod;

	return { module: mod };
}

/**
 * Whether the config sets basic auth (the main section's auth_user).
 *
 * @param {UciCursor} uci the cursor.
 * @returns {boolean} whether it sets a user.
 */
export function auth_wanted(uci) {
	let s = uci.get_all(config.NAME, 'main');
	let user = (type(s) == 'object' && s['.type'] == config.NAME) ? s.auth_user : null;

	return user != null && user != '';
};

/**
 * Basic auth as the handler finds it when it starts.
 *
 * @param {module:fs} fs what reads AUTH_FILE: an object of fs's readfile.
 * @param {boolean} wanted whether the config sets basic auth (auth_wanted).
 * @param {?string} program what loads basic auth's module; AUTH_PROGRAM when null.
 * @returns {?(BasicAuth|BrokenAuth)} basic auth.
 */
export function load_auth(fs, wanted, program) {
	let text = fs.readfile(AUTH_FILE);

	if (text == null)
		return wanted ? { broken: true, missing: true } : null;

	let loaded = auth_module(program);

	if (loaded.error != null)
		return { broken: true, unloaded: loaded.error };

	try {
		return loaded.module.parse_conf(text) ?? { broken: true };
	} catch (e) {
		return { broken: true, unloaded: split(e.message, '\n')[0] };
	}
};

/**
 * What the handler sends instead of a scrape, or null for a request it serves.
 *
 * @param {?(BasicAuth|BrokenAuth)} credentials basic auth, as load_auth gives it.
 * @param {?Object} env uhttpd-mod-ucode's env of the request.
 * @param {?State} instance the instance's state.
 * @param {?string} program what loads basic auth's module; AUTH_PROGRAM when null.
 * @returns {?HttpReply} the reply, or null.
 */
export function refusal(credentials, env, instance, program) {
	let broken = () => http.text_reply('500 Internal Server Error', 'Basic auth is not configured as it should be; see the log.\n');

	if (credentials == null)
		return null;

	if (credentials.broken)
		return broken();

	if (env?.HTTPS != 'on')
		return http.text_reply('403 Forbidden', 'Basic auth takes HTTPS only.\n');

	let auth = auth_module(program).module;
	let allowed = false;

	if (auth == null)
		return broken();

	try {
		allowed = auth.allowed(credentials, http.header(env, 'authorization'), instance);
	} catch (e) {
		return broken();
	}

	if (allowed !== true)
		return http.text_reply('401 Unauthorized', 'Unauthorized.\n',
			[ [ 'WWW-Authenticate', `Basic realm="${auth.REALM}"` ] ]);

	return null;
};

/**
 * The env a scrape runs collectors in, over the modules `mods` and log(level, msg).
 *
 * @param {Modules} mods the modules.
 * @param {Log} log the exporter's log.
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts the options.
 * @returns {ScrapeEnv} the env.
 */
export function scrape_env(mods, log, opts) {
	let observed = opts?.observed ?? mods;

	return {
		session: (to) => deps.session({ ...observed, log: to ?? log }),
		clock: () => clock(true),
		log,
		version: version(),
		fork: opts?.fork ?? true,
		tmp: opts?.tmp,
		mkstemp: mods.fs.mkstemp,
		open: mods.fs.open,
		readfile: mods.fs.readfile,
		kill: (pid) => deps.kill_tree(mods.fs.popen, pid),
	};
};

function loader_program() {
	return loadstring("import * as loader from 'prometheus.exporter.loader';\nreturn loader;", { raw_mode: true })();
}

/**
 * How many times a module whose file changed between check and load is tried.
 *
 * @type {int}
 */
export const CHECK_ROUNDS = 3;

function take(checked, log, import_all, import_one, changed) {
	let ids = map(checked, (x) => x.id);
	let together = null;
	let out = [];

	if (import_all && length(ids)) {
		try {
			together = import_all(ids);
		} catch (e) {
			log('notice', `cannot load the collectors as one program, so each is loaded alone: ${split(e.message, '\n')[0]}`);
		}
	}

	for (let x in checked) {
		let mod;

		try {
			mod = (together != null) ? together[x.id] : import_one(x.id);
		} catch (e) {
			log('err', collection.load_error(x.id, split(e.message, '\n')[0]));
			continue;
		}

		let meta = (type(mod?.meta) == 'object') ? { options: {}, ...mod.meta } : null;

		if (meta == null || type(mod.collect) != 'function' || collection.fingerprint(meta) != x.meta) {
			if (changed != null)
				push(changed, x.id);
			else
				log('err', `skipping collector: ${x.id}: not what it was when it was checked, in a process of its own`);
			continue;
		}

		push(out, { id: x.id, meta, collect: mod.collect, own: x.own });
	}

	return out;
}

function by_name(collectors) {
	return sort(collectors, (a, b) => a.meta.name < b.meta.name ? -1 : 1);
}

/**
 * The collectors of `checked`, loaded here as the probe's child checked them.
 *
 * @param {CheckedModule[]} checked the modules, as the loader's check gives them.
 * @param {Log} log the exporter's log.
 * @returns {Collector[]} the collectors.
 */
export function load_checked(checked, log) {
	return by_name(take(checked, log, collection.import_modules, collection.import_module));
};

/**
 * What load_probed() gives.
 *
 * @typedef {{ collectors: Collector[], stopped: ?int, unprobed: ?boolean }} ProbedLoad
 */

/**
 * The collectors `ids`, each checked in the probe's child, then loaded here.
 *
 * @param {string[]} ids the modules' names.
 * @param {function(string[]): Object<string, ProbeOutcome>} probe_fn checks the modules in a child.
 * @param {Log} log the exporter's log.
 * @param {?{ all: function(string[]): Object<string, CollectorModule>, one: function(string): CollectorModule }} imports
 * @returns {ProbedLoad} the collectors, or why there are none.
 */
export function load_probed(ids, probe_fn, log, imports) {
	let all = imports?.all ?? collection.import_modules;
	let one = imports?.one ?? collection.import_module;
	let collectors = [];
	let pending = ids;

	for (let round = 1; length(pending); round++) {
		let probed = probe_fn(pending);
		let checked = [];
		let again = [];

		for (let id in pending) {
			let p = probed[id];

			if (p?.stopped)
				return { collectors: [], stopped: p.stopped };
			if (p?.unprobed && round == 1)
				return { collectors: [], unprobed: true };
			if (p == null || p.unprobed) {
				push(again, id);
				continue;
			}

			let why = collection.left_out(id, p) ?? ((p.data?.invalid != null) ? `skipping collector: ${p.data.invalid}` : null);

			if (why != null)
				log('err', why);
			else
				push(checked, { id, meta: p.data?.meta, own: p.data?.own == true });
		}

		push(collectors, ...take(checked, log, (round == 1) ? all : null, one, again));

		if (!length(again))
			break;

		if (round >= CHECK_ROUNDS) {
			for (let id in again)
				log('err', `skipping collector: ${id}: not what it was when it was checked, in a process of its own, ${round} times: is it being upgraded?`);
			break;
		}

		log('info', `checking again what changed since it was checked, as in an upgrade: ${join(' ', again)}`);
		pending = again;
	}

	return { collectors: by_name(collectors) };
};

/**
 * The collectors in `dir`, checked in a process of their own and loaded as one program.
 *
 * @param {Modules} mods the modules.
 * @param {?string} dir the collectors' directory; collection.DIR when null.
 * @param {Log} log the exporter's log.
 * @param {?{ fork: ?boolean }} opts the options.
 * @returns {Collector[]} the collectors.
 */
export function load(mods, dir, log, opts) {
	dir ??= collection.DIR;

	if (opts?.fork ?? true) {
		let loader = null;
		let check = (id) => (loader ??= loader_program()).check_module(mods.fs, dir, id, collection.import_module);
		let res = load_probed(collection.discover(mods.fs, dir), (ids) => probe_modules(ids, check, null, null, true), log);

		if (res.stopped) {
			log('notice', `asked to stop (signal ${res.stopped}) while it loaded the collectors: stopping`);
			exit(128 + res.stopped);
		}

		if (!res.unprobed)
			return res.collectors;
	}

	return loader_program().load(mods.fs, dir, collection.import_module, log, null, collection.import_modules);
};

/**
 * The native modules uhttpd loads when it starts, where an enabled collector needs one: scrapes then load none.
 *
 * @type {string[]}
 */
export const NATIVES = [ 'ubus', 'rtnl', 'nl80211' ];

/**
 * What uhttpd loads when it starts whatever the collectors need: zlib, for gzip.
 *
 * @type {string[]}
 */
export const ALWAYS = [ 'zlib' ];

/**
 * The native modules of NATIVES that the enabled collectors of `collectors` need, in NATIVES' order.
 *
 * @param {Collector[]} collectors the installed collectors.
 * @param {?string[]} disabled the ids of those disabled; none when null.
 * @returns {string[]} the native modules they need.
 */
export function natives_of(collectors, disabled) {
	let wanted = {};

	for (let c in collectors)
		if (!(c.id in (disabled ?? [])))
			for (let need in c.meta.needs)
				wanted[need] = true;

	return filter(NATIVES, (n) => wanted[n]);
};

/**
 * What preload() gives: the modules it loaded here, and the signal that stopped it.
 *
 * @typedef {{ loaded: string[], stopped: ?int }} Preloaded
 */

/**
 * The modules `names`, each loaded in the probe's child first, then here when it loaded there.
 *
 * @param {string[]} names the modules' names.
 * @param {?function(string[]): Object<string, ProbeOutcome>} probe_fn loads them in a child first.
 * @param {function(string): boolean} load loads a module here, and says whether it loaded.
 * @param {Log} log the exporter's log.
 * @returns {Preloaded} what loaded, or the signal that stopped the probe.
 */
export function preload(names, probe_fn, load, log) {
	let probed = (probe_fn && length(names)) ? probe_fn(names) : null;
	let loaded = [];

	for (let name in names) {
		let p = probed?.[name];

		if (p?.stopped)
			return { loaded, stopped: p.stopped };

		if (probed != null && !(p?.ok && p.data === true)) {
			if (p != null && !p.ok)
				log('warning', `native module '${name}' did not load in a process of its own: ${p.error}; each scrape loads it where it needs it`);
			continue;
		}

		if (load(name))
			push(loaded, name);
	}

	return { loaded, stopped: null };
};

function load_native(native, name) {
	return (name == 'zlib') ? http.load_zlib() : (native?.(name) != null);
}

/**
 * { collectors(), scrape(query_string) }.
 *
 * @param {Log} log the exporter's log.
 * @param {?string} dir the collectors' directory; collection.DIR when null.
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts the options: scrape_env()'s.
 * @returns {App} the exporter.
 */
export function create(log, dir, opts) {
	let mods = deps.modules();
	let env = scrape_env(mods, log, opts);
	let loaded = load(mods, dir, log, opts);

	return {
		collectors: () => loaded,
		scrape: (query_string, opts) => scrape.scrape(env, loaded, query_string, opts),
		mods,
	};
};

/**
 * The exporter as uhttpd's handler.
 *
 * @param {Log} log the exporter's log.
 * @param {?string} dir the collectors' directory; collection.DIR when null.
 * @param {?string} state_dir the state's directory; state.DIR when null.
 * @param {?{ fork: ?boolean, observed: ?Modules, auth_program: ?string }} opts create()'s and more.
 * @returns {Handler} the handler.
 */
export function handler(log, dir, state_dir, opts) {
	let app = create(log, dir, { tmp: state_dir ?? state.DIR, ...(opts ?? {}) });
	let main = config.main(app.mods.uci.cursor());
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;
	let scrape_timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let program = opts?.auth_program;
	let credentials = load_auth(app.mods.fs, auth_wanted(app.mods.uci.cursor()), program);
	let instance = state.open(app.mods.fs, state_dir ?? state.DIR, state.instance_id(app.mods.fs));
	let native = (opts?.observed ?? app.mods).native;
	let names = [ ...(native ? natives_of(app.collectors(), config.disabled(app.mods.uci.cursor(), map(app.collectors(), (c) => c.id))) : []), ...ALWAYS ];
	let probe_fn = (opts?.fork ?? true) ? (pending) => probe_modules(pending, (name) => load_native(native, name), null, null, true) : null;
	let natives = preload(names, probe_fn, (name) => load_native(native, name), log);

	if (natives.stopped) {
		log('notice', `asked to stop (signal ${natives.stopped}) while it loaded the collectors: stopping`);
		exit(128 + natives.stopped);
	}

	if (credentials?.missing)
		log('err', `${AUTH_FILE} is not there, and the config sets basic auth (auth_user): every request is denied`);
	else if (credentials?.unloaded != null)
		log('err', `cannot load basic auth's module, and ${AUTH_FILE} is there: ${credentials.unloaded}: every request is denied`);
	else if (credentials?.broken)
		log('err', `${AUTH_FILE} is not one line of a user and a hash for ${auth_module(program).module.PATH}: every request is denied`);

	return {
		collectors: app.collectors,
		auth: credentials,
		natives: natives.loaded,
		compress,
		scrape_timeout,
		handle: function(req) {
			let start = deadline.seconds(clock(true));
			let refused = refusal(credentials, req, instance, program);

			if (refused?.status == '401 Unauthorized')
				instance.update(ledger.NAME, (text) => ledger.serialize(ledger.auth_failure(ledger.parse(text))));

			if (refused)
				return refused;

			let budget = deadline.budget(deadline.timeout(http.header(req, deadline.HEADER), scrape_timeout));
			let res = app.scrape(req?.QUERY_STRING, { deadline: start + budget, budget, state: instance });

			return http.scrape_reply(res, http.header(req, 'accept-encoding'), compress);
		},
	};
};
