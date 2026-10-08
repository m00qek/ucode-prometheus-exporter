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
import * as loader from 'prometheus_exporter.loader';
import * as scrape from 'prometheus_exporter.scrape';
import * as config from 'prometheus_exporter.config';
import * as auth from 'prometheus_exporter.auth';
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
 * though the config sets basic auth.
 *
 * @typedef {{ broken: boolean, missing: ?boolean }} BrokenAuth
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
 * uhttpd's config file (auth.FILE) is that; null when it is not there and
 * the config sets no basic auth (`wanted` false), as the jail mounts it only
 * when it does. Every other case denies every request: { broken: true } when
 * it is there but not that, { broken: true, missing: true } when the config
 * sets basic auth and it is not there, as when procd starts uhttpd again
 * after the file went: never served without the login the config asks for.
 *
 * @param {module:fs} fs what reads auth.FILE: an object of fs's readfile.
 * @param {boolean} wanted whether the config sets basic auth (auth_wanted).
 * @returns {?(BasicAuth|BrokenAuth)} basic auth.
 */
export function load_auth(fs, wanted) {
	let text = fs.readfile(auth.FILE);

	if (text == null)
		return wanted ? { broken: true, missing: true } : null;

	return auth.parse_conf(text) ?? { broken: true };
};

/**
 * What the handler sends instead of a scrape, or null for a request it serves.
 * Basic auth answers 403 to a request over HTTP, which the init script never
 * listens on with it, and 401 to one without the user and password. `instance`, the
 * instance's state, holds basic auth's cache (auth.allowed).
 *
 * @param {?(BasicAuth|BrokenAuth)} credentials basic auth, as load_auth gives
 *   it.
 * @param {?Object} env uhttpd-mod-ucode's env of the request.
 * @param {?State} instance the instance's state.
 * @returns {?HttpReply} the reply, or null.
 */
export function refusal(credentials, env, instance) {
	if (credentials == null)
		return null;

	if (credentials.broken)
		return http.text_reply('500 Internal Server Error', 'Basic auth is not configured as it should be; see the log.\n');

	if (env?.HTTPS != 'on')
		return http.text_reply('403 Forbidden', 'Basic auth takes HTTPS only.\n');

	if (!auth.allowed(credentials, http.header(env, 'authorization'), instance))
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
		readfile: mods.fs.readfile,
		// A collector's child process, with every process under it: one
		// the runner stops, or one its scrape left behind
		// (prometheus_exporter.progress's bury). ash's kill, as the jail has
		// no kill program (deps.kill_tree).
		kill: (pid) => deps.kill_tree(mods.fs.popen, pid),
	};
};

/**
 * The collectors in `dir` (loader.DIR), as the exporter loads them: each
 * probed first in a process of its own (prometheus_exporter.probe),
 * unless opts.fork is false, and then all of them loaded as one program
 * (loader.import_modules), which compiles what they share once.
 *
 * @param {Modules} mods the modules.
 * @param {?string} dir the collectors' directory; loader.DIR when null.
 * @param {Log} log the exporter's log.
 * @param {?{ fork: ?boolean }} opts the options.
 * @returns {Collector[]} the collectors.
 */
export function load(mods, dir, log, opts) {
	let probe = (opts?.fork ?? true) ? (ids) => probe_modules(ids, loader.import_module) : null;

	return loader.load(mods.fs, dir ?? loader.DIR, loader.import_module, log, probe, loader.import_modules);
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
 * @param {?string} dir the collectors' directory; loader.DIR when null.
 * @param {?{ fork: ?boolean, tmp: ?string, observed: ?Modules }} opts the
 *   options: scrape_env()'s.
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
 * The exporter as uhttpd's handler: { collectors(), auth, compress,
 * scrape_timeout, handle(env) }, where handle answers one request
 * (uhttpd-mod-ucode's env) with a reply (prometheus_exporter.http), in the time
 * the scraper gives it (prometheus_exporter.deadline), counted from when the
 * request reached the handler. Like the collectors, compress, scrape_timeout
 * and basic auth are read once, when the handler starts: a change of the config
 * restarts uhttpd (see the init script). `auth` is load_auth's. The state is
 * opened here too, in the process uhttpd forks each request from, which names
 * the instance (see prometheus_exporter.state); `state_dir` replaces its
 * directory, for tests.
 *
 * @param {Log} log the exporter's log.
 * @param {?string} dir the collectors' directory; loader.DIR when null.
 * @param {?string} state_dir the state's directory; state.DIR when null.
 * @param {?{ fork: ?boolean, observed: ?Modules }} opts the options: create()'s.
 * @returns {Handler} the handler.
 */
export function handler(log, dir, state_dir, opts) {
	// The jail has no /tmp: the state's directory, on tmpfs, is the one it writes.
	let app = create(log, dir, { tmp: state_dir ?? state.DIR, ...(opts ?? {}) });
	let main = config.main(app.mods.uci.cursor());
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;
	let scrape_timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let credentials = load_auth(app.mods.fs, auth_wanted(app.mods.uci.cursor()));
	let instance = state.open(app.mods.fs, state_dir ?? state.DIR, state.instance_id(app.mods.fs));

	if (credentials?.missing)
		log('err', `${auth.FILE} is not there, and the config sets basic auth (auth_user): every request is denied`);
	else if (credentials?.broken)
		log('err', `${auth.FILE} is not one line of a user and a hash for ${auth.PATH}: every request is denied`);

	return {
		collectors: app.collectors,
		auth: credentials,
		compress,
		scrape_timeout,
		handle: function(req) {
			let start = deadline.seconds(clock(true));
			let refused = refusal(credentials, req, instance);

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
