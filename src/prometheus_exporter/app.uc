/**
 * The exporter on the real system; the uhttpd handler and the command line both
 * start here.
 *
 * @module prometheus_exporter_app
 */

'use strict';

// First, so that its functions are the program's first: ucode finds the
// function a closure is made of by walking the program's functions from the
// first it compiled, so a closure of a module compiled after the rest costs
// a step for each function before it. The recorder makes closures for each
// collector a scrape runs, and for each family it writes: imported after
// the others, it took a scrape 16 us more a collector in the devenv, a
// tenth more than now, and each family more again.
import * as exposition from 'prometheus_exporter.exposition';
import * as deps from 'prometheus_exporter.deps';
import * as collection from 'prometheus_exporter.collection';
import * as scrape from 'prometheus_exporter.scrape';
import * as config from 'prometheus_exporter.config';
import * as http from 'prometheus_exporter.http';
import * as state from 'prometheus_exporter.state';
import * as deadline from 'prometheus_exporter.deadline';
import * as ledger from 'prometheus_exporter.ledger';
import * as runner from 'prometheus_exporter.runner';
import { probe as probe_modules } from 'prometheus_exporter.probe';
import { version } from 'prometheus_exporter.version';

/**
 * The exporter, as create() gives it: its collectors, a scrape of a query
 * string, and the modules it runs over.
 *
 * @typedef {{
 *   collectors: () => Collector[],
 *   scrape: (query_string: ?string, opts: ?ScrapeOptions) => ScrapeReply,
 *   mods: Modules
 * }} App
 */

/**
 * Basic auth that denies every request, as load_auth gives it: uhttpd's
 * config file is there and not what it should be, or `missing`, not there
 * though the config sets basic auth, or `unloaded`, there though basic
 * auth's module did not load, which says why.
 *
 * @typedef {{ broken: boolean, missing: ?boolean, unloaded: ?string }} BrokenAuth
 */

/**
 * The exporter as uhttpd's handler, as handler() gives it: its collectors,
 * basic auth (load_auth's), compress and scrape_timeout as the handler read
 * them, and handle(env), the reply to a request (uhttpd-mod-ucode's env).
 *
 * @typedef {{
 *   collectors: () => Collector[],
 *   auth: ?(BasicAuth|BrokenAuth),
 *   compress: boolean,
 *   scrape_timeout: int,
 *   handle: (req: Object) => HttpReply
 * }} Handler
 */

/**
 * uhttpd's config file of basic auth, which the init script writes
 * (prometheus_exporter.auth's FILE).
 *
 * @type {string}
 */
export const AUTH_FILE = `${state.RUN_DIR}/uhttpd.conf`;

/**
 * The program that loads basic auth's module (prometheus_exporter.auth),
 * which the handler compiles the first time it needs it, as a program of its
 * own: when it starts, only where AUTH_FILE is there, and then keeps it.
 * Without basic auth, uhttpd, which holds what it compiles for as long as it
 * runs, holds none of it, nor of crypt, nor ucode-mod-digest.
 *
 * @type {string}
 */
export const AUTH_PROGRAM = "import * as auth from 'prometheus_exporter.auth';\nreturn auth;";

// AUTH_PROGRAM's module, once it loaded.
let auth_loaded = null;

// Basic auth's module, as { module }, from `source` (AUTH_PROGRAM when null,
// kept once it loads; another, a test's, compiled each time), or { error }
// when it does not compile, load or give what the handler takes of it:
// whatever the reason (a file missing, or not mounted, a syntax error, no
// memory left), the handler then denies every request, never serves one.
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
		return { error: 'it is not prometheus_exporter.auth' };

	if (source == null)
		auth_loaded = mod;

	return { module: mod };
}

/**
 * Whether the config sets basic auth: the main section's auth_user, as uci
 * holds it, whatever else the section says. The jail mounts the exporter's
 * config, so the handler reads it as the init script does.
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
 * Basic auth as the handler finds it when it starts: { user, hash } when
 * uhttpd's config file (AUTH_FILE) is that; null when it is not there and
 * the config sets no basic auth (`wanted` false), as the jail mounts it only
 * when it does. Every other case denies every request: { broken: true } when
 * it is there but not that, { broken: true, missing: true } when the config
 * sets basic auth and it is not there, as when procd starts uhttpd again
 * after the file went: never served without the login the config asks for.
 *
 * It compiles basic auth's module (`program`, AUTH_PROGRAM when null) only
 * when the file is there, and denies every request when that fails:
 * { broken: true, unloaded: why }.
 *
 * @param {module:fs} fs what reads AUTH_FILE: an object of fs's readfile.
 * @param {boolean} wanted whether the config sets basic auth (auth_wanted).
 * @param {?string} program what loads basic auth's module; AUTH_PROGRAM
 *   when null.
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
 * Basic auth answers 403 to a request over HTTP, which the init script never
 * listens on with it, and 401 to one without the user and password. `instance`, the
 * instance's state, holds basic auth's cache (auth.allowed).
 *
 * Basic auth's module is load_auth's (`program`, AUTH_PROGRAM when null):
 * should it not load, or its check throw, the request is denied with a 500.
 *
 * @param {?(BasicAuth|BrokenAuth)} credentials basic auth, as load_auth gives
 *   it.
 * @param {?Object} env uhttpd-mod-ucode's env of the request.
 * @param {?State} instance the instance's state.
 * @param {?string} program what loads basic auth's module; AUTH_PROGRAM
 *   when null.
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
 * The env a scrape runs collectors in (prometheus_exporter.scrape), over the
 * modules `mods` and log(level, msg): each collector in a process of its own
 * (prometheus_exporter.runner), unless opts.fork is false; opts.tmp is the
 * directory of the file their runs cross by (/tmp). opts.observed replaces
 * `mods` for what the collectors read (deps.session), and for that alone: the
 * benchmark's worlds.
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
		// A collector's child process, with every process under it: one
		// the runner stops, or one its scrape left behind
		// (prometheus_exporter.progress's bury). ash's kill, as the jail has
		// no kill program (deps.kill_tree).
		kill: (pid) => deps.kill_tree(mods.fs.popen, pid),
	};
};

// The loader (prometheus_exporter.loader), compiled as a program of its own:
// it checks what each module may be, and serves no scrape.
function loader_program() {
	return loadstring("import * as loader from 'prometheus_exporter.loader';\nreturn loader;", { raw_mode: true })();
}

/**
 * How many times a module is checked in the probe's child and loaded here,
 * at most, when it is not, once loaded, what was checked: when its file
 * changed in between, as in an upgrade of several packages.
 *
 * @type {int}
 */
export const CHECK_ROUNDS = 3;

// The collectors of `checked` loaded here: as one program with import_all,
// when given, else each alone with import_one; and each alone when that
// throws. Each as the loader took it in the probe's child, its meta that
// one (its fingerprint). One that is not is left out: its id pushed to
// `changed`, when given, for it to be checked again, or else logged at err.
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
 * The collectors of `checked` (the loader's check), loaded here as one
 * program, or each alone when that throws: each as the loader took it in
 * the probe's child, its meta that one (its fingerprint), and left out,
 * logged at err, when it is not; sorted by name.
 *
 * @param {CheckedModule[]} checked the modules, as the loader's check gives
 *   them.
 * @param {Log} log the exporter's log.
 * @returns {Collector[]} the collectors.
 */
export function load_checked(checked, log) {
	return by_name(take(checked, log, collection.import_modules, collection.import_module));
};

/**
 * What load_probed() gives: the collectors, sorted by name; `stopped`, the
 * signal that asked this process to stop while the probe loaded them, and
 * then no collectors; `unprobed`, when no child process could be forked to
 * check them, and then none either.
 *
 * @typedef {{ collectors: Collector[], stopped: ?int, unprobed: ?boolean }} ProbedLoad
 */

/**
 * The collectors `ids`, each checked in the probe's child first
 * (probe_fn(ids): the probe's outcomes, the loader's check_module's report
 * their `data`), then loaded here, all as one program (imports.all), as it
 * was checked there, or not at all.
 *
 * A module whose file changed between its check and its load, as in an
 * upgrade of several packages, which reloads the service after each, is not
 * what was checked: it is checked again and loaded alone (imports.one), up
 * to CHECK_ROUNDS times, and left out, logged at err, only when it changed
 * each time. So is a module the probe gave no outcome of. One the probe left
 * out (it hung, did not load, or is not a valid collector) is logged at err.
 *
 * @param {string[]} ids the modules' names.
 * @param {function(string[]): Object<string, ProbeOutcome>} probe_fn what
 *   checks the modules in a child process.
 * @param {Log} log the exporter's log.
 * @param {?{ all: function(string[]): Object<string, CollectorModule>, one: function(string): CollectorModule }} imports
 *   what loads the modules here: collection.import_modules and
 *   import_module when null.
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

		// The first round's as one program; a module checked again alone,
		// compiled anew from what its file is now.
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
 * The collectors in `dir` (collection.DIR), as the exporter loads them: each
 * checked first in a process of its own (prometheus_exporter.probe), its
 * text and then its exports, as the loader checks them (its check_module),
 * unless opts.fork is false, and then all of them loaded as one program
 * (collection.import_modules), which compiles what they share once
 * (load_probed). The loader is compiled in that process alone: uhttpd holds
 * what its own program loads for as long as it runs, and the loader serves
 * no scrape. Without a child, it is compiled here, as a program of its own,
 * and checks them here, as before there was one.
 *
 * A process asked to stop (SIGTERM, SIGINT) while the probe waits for its
 * child ends here, as the signal would have ended it: uloop takes the
 * signal while it waits, and uhttpd, which runs the handler before its own
 * loop, would forget it, and serve without collectors until procd killed
 * it (prometheus_exporter.probe).
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
		// Compiled in the probe's child, at its first module.
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
 * { collectors(), scrape(query_string) }. log(level, msg) takes what the
 * loader, the scrapes and the collectors log (deps.LEVELS). `dir` replaces the
 * installed collectors' directory, for running from a source tree. opts.fork
 * false runs every collector, and loads every module, in this process.
 *
 * The collectors are loaded once: installing, removing or upgrading a
 * collector package reloads the service, which restarts uhttpd when the
 * collectors changed (see the init script).
 *
 * @param {Log} log the exporter's log.
 * @param {?string} dir the collectors' directory; collection.DIR when null.
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts the
 *   options: scrape_env()'s.
 * @returns {App} the exporter.
 */
export function create(log, dir, opts) {
	// The native modules the collectors need besides fs and uci are loaded
	// when one runs, in its process (deps.native), not here.
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
 * The exporter as uhttpd's handler: { collectors(), auth, compress,
 * scrape_timeout, handle(env) }, where handle answers one request
 * (uhttpd-mod-ucode's env) with a reply (prometheus_exporter.http), in the time
 * the scraper gives it (prometheus_exporter.deadline), counted from when the
 * request reached the handler. Like the collectors, compress, scrape_timeout
 * and basic auth are read once, when the handler starts: a change of the config
 * restarts uhttpd (see the init script). `auth` is load_auth's. The state is
 * opened here too, in the process uhttpd forks each request from, which names
 * the instance (see prometheus_exporter.state); `state_dir` replaces its
 * directory, for tests, and opts.auth_program basic auth's AUTH_PROGRAM.
 *
 * @param {Log} log the exporter's log.
 * @param {?string} dir the collectors' directory; collection.DIR when null.
 * @param {?string} state_dir the state's directory; state.DIR when null.
 * @param {?{ fork: ?boolean, observed: ?Modules, auth_program: ?string }} opts
 *   the options: create()'s, and what loads basic auth's module.
 * @returns {Handler} the handler.
 */
export function handler(log, dir, state_dir, opts) {
	// The jail has no /tmp: the state's directory, on tmpfs, is the one it writes.
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

			// Counted for the exporter's own collector: a 401 is a request
			// whose credentials basic auth refused.
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
