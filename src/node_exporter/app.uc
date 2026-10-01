'use strict';

// The exporter on the real system; the uhttpd handler and the command line both
// start here.

import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as scrape from 'node_exporter.scrape';

// { collectors(), scrape(query_string) }. `dir` replaces the installed
// collectors' directory, for running from a source tree.
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
	};
	let loaded = loader.load(mods.fs, dir ?? loader.DIR, loader.import_module, log);

	return {
		collectors: () => loaded,
		scrape: (query_string) => scrape.scrape(env, loaded, query_string),
	};
};
