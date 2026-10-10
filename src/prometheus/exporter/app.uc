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
 *   compress: boolean,
 *   scrape_timeout: int,
 *   handle: (req: Object) => HttpReply
 * }} Handler
 */

/** uhttpd's config file of basic auth, which the init script writes. */
export const AUTH_FILE = `${state.RUN_DIR}/uhttpd.conf`;

/** The program that loads basic auth's module, compiled the first time it is needed. */
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
 * @param {UciCursor} uci
 * @returns {boolean}
 */
export function auth_wanted(uci) {
	let s = uci.get_all(config.NAME, 'main');
	let user = (type(s) == 'object' && s['.type'] == config.NAME) ? s.auth_user : null;

	return user != null && user != '';
};

/**
 * Basic auth as the handler finds it when it starts.
 *
 * @param {module:fs} fs
 * @param {boolean} wanted
 * @param {?string} program
 * @returns {?(BasicAuth|BrokenAuth)}
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
 * @param {?(BasicAuth|BrokenAuth)} credentials
 * @param {?Object} env
 * @param {?State} instance
 * @param {?string} program
 * @returns {?HttpReply}
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
 * @param {Modules} mods
 * @param {Log} log
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts
 * @returns {ScrapeEnv}
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

/** How many times a module whose file changed between check and load is tried. */
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
 * @param {CheckedModule[]} checked
 * @param {Log} log
 * @returns {Collector[]}
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
 * @param {string[]} ids
 * @param {function(string[]): Object<string, ProbeOutcome>} probe_fn
 * @param {Log} log
 * @param {?{ all: function(string[]): Object<string, CollectorModule>, one: function(string): CollectorModule }} imports
 * @returns {ProbedLoad}
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
 * @param {Modules} mods
 * @param {?string} dir
 * @param {Log} log
 * @param {?{ fork: ?boolean }} opts
 * @returns {Collector[]}
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
 * { collectors(), scrape(query_string) }.
 *
 * @param {Log} log
 * @param {?string} dir
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts
 * @returns {App}
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
 * @param {Log} log
 * @param {?string} dir
 * @param {?string} state_dir
 * @param {?{ fork: ?boolean, observed: ?Modules, auth_program: ?string }} opts
 * @returns {Handler}
 */
export function handler(log, dir, state_dir, opts) {
	let app = create(log, dir, { tmp: state_dir ?? state.DIR, ...(opts ?? {}) });
	let main = config.main(app.mods.uci.cursor());
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;
	let scrape_timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let program = opts?.auth_program;
	let credentials = load_auth(app.mods.fs, auth_wanted(app.mods.uci.cursor()), program);
	let instance = state.open(app.mods.fs, state_dir ?? state.DIR, state.instance_id(app.mods.fs));

	if (credentials?.missing)
		log('err', `${AUTH_FILE} is not there, and the config sets basic auth (auth_user): every request is denied`);
	else if (credentials?.unloaded != null)
		log('err', `cannot load basic auth's module, and ${AUTH_FILE} is there: ${credentials.unloaded}: every request is denied`);
	else if (credentials?.broken)
		log('err', `${AUTH_FILE} is not one line of a user and a hash for ${auth_module(program).module.PATH}: every request is denied`);

	return {
		collectors: app.collectors,
		auth: credentials,
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
