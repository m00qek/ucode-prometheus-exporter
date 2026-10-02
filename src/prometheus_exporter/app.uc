'use strict';

// The exporter on the real system; the uhttpd handler and the command line both
// start here.

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
import { version } from 'prometheus_exporter.version';

// Basic auth as the handler finds it when it starts: null when uhttpd's
// config file (auth.FILE) is not there, which the jail mounts only when the
// main section sets basic auth; { user, hash } when it is that; { broken: true }
// when it is there but not that, which denies every request.
export function load_auth(fs) {
	let text = fs.readfile(auth.FILE);

	if (text == null)
		return null;

	return auth.parse_conf(text) ?? { broken: true };
};

// What the handler sends instead of a scrape, or null for a request it serves.
// Basic auth answers 403 to a request over HTTP, which the init script never
// listens on with it, and 401 to one without the user and password. `st`, the
// instance's state, holds basic auth's cache (auth.allowed).
export function refusal(a, env, st) {
	if (a == null)
		return null;

	if (a.broken)
		return http.text_reply('500 Internal Server Error', 'Basic auth is not configured as it should be; see the log.\n');

	if (env?.HTTPS != 'on')
		return http.text_reply('403 Forbidden', 'Basic auth takes HTTPS only.\n');

	if (!auth.allowed(a, http.header(env, 'authorization'), st))
		return http.text_reply('401 Unauthorized', 'Unauthorized.\n',
			[ [ 'WWW-Authenticate', `Basic realm="${auth.REALM}"` ] ]);

	return null;
};

// The env a scrape runs collectors in (prometheus_exporter.scrape), over the
// modules `mods` and log(level, msg): each collector in a process of its own
// (prometheus_exporter.runner), unless opts.fork is false; opts.tmp is the
// directory of the file their runs cross by (/tmp).
export function scrape_env(mods, log, opts) {
	return {
		session: (to) => deps.session({ ...mods, log: to ?? log }),
		clock: () => clock(true),
		log,
		version: version(),
		fork: opts?.fork ?? true,
		tmp: opts?.tmp,
		mkstemp: mods.fs.mkstemp,
		readfile: mods.fs.readfile,
		// A collector's child process its scrape left behind
		// (scrape.bury): ash's kill, as the jail has no kill program.
		kill: function(pid) {
			let p = mods.fs.popen(`kill -KILL ${int(pid)} 2>/dev/null`, 'r');

			p?.read('all');
			p?.close();
		},
	};
};

// The collectors in `dir` (loader.DIR), as the exporter loads them: each
// probed first in a process of its own (prometheus_exporter.runner's probe),
// unless opts.fork is false.
export function load(mods, dir, log, opts) {
	let probe = (opts?.fork ?? true) ? (ids) => runner.probe(ids, loader.import_module) : null;

	return loader.load(mods.fs, dir ?? loader.DIR, loader.import_module, log, probe);
};

// { collectors(), scrape(query_string) }. log(level, msg) takes what the
// loader, the scrapes and the collectors log (deps.LEVELS). `dir` replaces the
// installed collectors' directory, for running from a source tree. opts.fork
// false runs every collector, and loads every module, in this process.
//
// The collectors are loaded once: installing, removing or upgrading a
// collector package reloads the service, which restarts uhttpd when the
// collectors changed (see the init script).
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

// The exporter as uhttpd's handler: { collectors(), auth, compress,
// scrape_timeout, handle(env) }, where handle answers one request
// (uhttpd-mod-ucode's env) with a reply (prometheus_exporter.http), in the time
// the scraper gives it (prometheus_exporter.deadline), counted from when the
// request reached the handler. Like the collectors, compress, scrape_timeout
// and basic auth are read once, when the handler starts: a change of the config
// restarts uhttpd (see the init script). `auth` is load_auth's. The state is
// opened here too, in the process uhttpd forks each request from, which names
// the instance (see prometheus_exporter.state); `state_dir` replaces its
// directory, for tests.
export function handler(log, dir, state_dir, opts) {
	// The jail has no /tmp: the state's directory, on tmpfs, is the one it writes.
	let app = create(log, dir, { tmp: state_dir ?? state.DIR, ...(opts ?? {}) });
	let main = config.main(app.mods.uci.cursor());
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;
	let scrape_timeout = main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT;
	let a = load_auth(app.mods.fs);
	let st = state.open(app.mods.fs, state_dir ?? state.DIR, state.instance_id(app.mods.fs));

	if (a?.broken)
		log('err', `${auth.FILE} is not one line of a user and a hash for ${auth.PATH}: every request is denied`);

	return {
		collectors: app.collectors,
		auth: a,
		compress,
		scrape_timeout,
		handle: function(req) {
			let start = deadline.seconds(clock(true));
			let refused = refusal(a, req, st);

			// Counted for the exporter's own collector: a 401 is a request
			// whose credentials basic auth refused.
			if (refused?.status == '401 Unauthorized')
				st.update(ledger.NAME, (text) => ledger.serialize(ledger.auth_failure(ledger.parse(text))));

			if (refused)
				return refused;

			let budget = deadline.budget(deadline.timeout(http.header(req, deadline.HEADER), scrape_timeout));
			let res = app.scrape(req?.QUERY_STRING, { deadline: start + budget, budget, state: st });

			return http.scrape_reply(res, http.header(req, 'accept-encoding'), compress);
		},
	};
};
