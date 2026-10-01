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

// { collectors(), scrape(query_string) }. log(level, msg) takes what the
// loader, the scrapes and the collectors log (deps.LEVELS). `dir` replaces the
// installed collectors' directory, for running from a source tree.
//
// The collectors are loaded once: installing, removing or upgrading a
// collector package reloads the service, which restarts uhttpd when the
// collectors changed (see the init script).
export function create(log, dir) {
	let mods = deps.modules();
	let env = {
		session: () => deps.session({ ...mods, log }),
		clock: () => clock(true),
		log,
		version: version(),
	};
	let loaded = loader.load(mods.fs, dir ?? loader.DIR, loader.import_module, log);

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
export function handler(log, dir, state_dir) {
	let app = create(log, dir);
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

			if (refused)
				return refused;

			let budget = deadline.budget(deadline.timeout(http.header(req, deadline.HEADER), scrape_timeout));
			let res = app.scrape(req?.QUERY_STRING, { deadline: start + budget, budget, state: st });

			return http.scrape_reply(res, http.header(req, 'accept-encoding'), compress);
		},
	};
};
