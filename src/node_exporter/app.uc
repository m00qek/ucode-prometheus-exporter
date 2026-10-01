'use strict';

// The exporter on the real system; the uhttpd handler and the command line both
// start here.

import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as scrape from 'node_exporter.scrape';

// { collectors(), scrape(query_string) }. `dir` replaces the installed
// collectors' directory, for running from a source tree.
//
// The collectors are loaded again when their files change, so installing,
// removing or upgrading a collector package takes effect on the next scrape,
// without restarting uhttpd.
export function create(log, dir) {
	let mods = deps.modules();
	let env = {
		session: () => deps.session({ ...mods, log }),
		clock: () => clock(true),
		log,
	};
	let loaded = [];
	let seen = null;

	dir ??= loader.DIR;

	function collectors() {
		let now = loader.fingerprint(mods.fs, dir);

		if (now !== seen) {
			loaded = loader.load(mods.fs, dir, loader.import_module, log);
			seen = now;
		}

		return loaded;
	}

	return {
		collectors,
		scrape: (query_string) => scrape.scrape(env, collectors(), query_string),
	};
};
