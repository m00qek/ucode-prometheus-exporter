'use strict';

// with_mods(cfg, cb): inject utest's mocks (strict unless cfg says otherwise) and
// call cb with module-shaped objects for deps.session(), as deps.modules() gives
// the real ones.
//
// with_collector(mod, cfg, cb): run one collector module the way a scrape does,
// with only its needs, and call cb with { result, text, lines, logs, families };
// `logs` has what the scrape and the collector itself logged.
// Its output must parse as exposition text, or the test fails.
//
// cfg: { fs, ubus, uci, rtnl, nl80211 }: each mock's config ({ data, commands, errors, ... });
//      options: the collector's `config collector` section;
//      main: the main section; no_nl80211, no_rtnl: as if that module were missing;
//      time: what deps.time.now() returns.

import { mock } from 'utest';
import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as scrape from 'node_exporter.scrape';
import * as exposition from 'node_exporter.exposition';
import * as config from 'node_exporter.config';
import * as Result from 'node_exporter.result';

const MOCKED = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211' ];

function uci_config(cfg, id) {
	let data = { ...(cfg.uci?.data ?? {}) };
	let pkg = { ...(data[config.PACKAGE] ?? {}) };

	if (cfg.main)
		pkg.main = { '.type': config.PACKAGE, ...cfg.main };
	if (cfg.options && id)
		pkg[id] = { '.type': 'collector', ...cfg.options };

	data[config.PACKAGE] = pkg;
	return { ...(cfg.uci ?? {}), data };
}

function inject_each(cfgs, names, proxies, cb) {
	if (!length(names))
		return cb(proxies);

	let name = names[0];
	mock.inject(name, { strict: true, data: {}, ...cfgs[name] }, function(proxy) {
		proxies[name] = proxy;
		inject_each(cfgs, slice(names, 1), proxies, cb);
	});
}

export function with_mods(cfg, cb, id) {
	let cfgs = {};

	for (let name in MOCKED)
		cfgs[name] = cfg[name] ?? {};
	cfgs.uci = uci_config(cfg, id);

	inject_each(cfgs, MOCKED, {}, (p) => cb({
		fs: p.fs,
		ubus: p.ubus,
		uci: p.uci,
		rtnl: cfg.no_rtnl ? null : p.rtnl,
		nl80211: cfg.no_nl80211 ? null : p.nl80211,
		time: () => cfg.time ?? 0,
	}));
};

export function with_collector(mod, cfg, cb) {
	let id = loader.id_of(mod.meta?.name ?? '');
	let valid = loader.validate(id, mod);

	if (!valid.ok)
		die(Result.describe(valid));

	with_mods(cfg, function(mods) {
		let logs = [];
		let session = deps.session({ ...mods, log: (msg) => push(logs, msg) });
		let env = { session: () => session, clock: () => [ 0, 0 ], log: (msg) => push(logs, msg) };
		let run = scrape.run_one(env, session, valid.data);

		session.close();

		let text = exposition.render(run.families);
		let parsed = exposition.parse(text);
		if (!parsed.ok)
			die(`${mod.meta.name} wrote invalid exposition text: ${Result.describe(parsed)}\n${text}`);

		cb({
			result: run.result,
			text,
			lines: text == '' ? [] : split(rtrim(text, '\n'), '\n'),
			logs,
			families: run.families,
		});
	}, id);
};
