'use strict';

// The exporter on the real system; the uhttpd handler and the command line both
// start here.

import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as scrape from 'node_exporter.scrape';

// { collectors, scrape(query_string) }. `dir` replaces the installed collectors'
// directory, for running from a source tree.
export function create(log, dir) {
	let mods = deps.modules();
	let collectors = loader.load(mods.fs, dir ?? loader.DIR, loader.import_module, log);
	let env = {
		session: () => deps.session(mods),
		clock: () => clock(true),
		log,
	};

	return {
		collectors,
		scrape: (query_string) => scrape.scrape(env, collectors, query_string),
	};
};
