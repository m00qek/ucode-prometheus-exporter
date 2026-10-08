'use strict';

// What the tests of the ubus object (prometheus_exporter.rpc, .rpc.describe,
// .rpc.validate) run on: test collectors as the loader returns them, apk's
// lists of a few, and a sys over utest's mocks.

import * as rpc from 'prometheus_exporter.rpc';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import * as Result from 'prometheus_exporter.result';
import * as fixtures from 'lib.fixtures';
import { with_mods } from 'context';

export const NAME = config.NAME;

// Read before any mock is active: fs is mocked too.
export const ROUTER_INTERFACES = fixtures.ubus('caju-router', 'network.interface', 'dump');
export const PACKAGE = config.PACKAGE;
export const DIR = '/collectors';
export const APK = '/apk';

// A collector as the loader returns it. Options may be given as bare defaults:
// they get the title and help the loader requires.
export function collector(name, meta, collect) {
	let options = {};

	for (let k, v in meta?.options ?? {})
		options[k] = (type(v) == 'object') ? v : { default: v, title: k, help: `The ${k} option.` };

	let res = loader.validate(loader.id_of(name), {
		meta: { name, title: name, help: `The ${name} test collector.`, needs: [], ...meta, options },
		collect: collect ?? (() => Result.ok()),
	});

	if (!res.ok)
		die(Result.describe(res));

	return res.data;
};

export const LOADAVG = collector('loadavg', { needs: [ 'fs' ] });
export const WIFI = collector('wifi', { needs: [ 'ubus' ], options: { stations: true } });
export const TEXTFILE = collector('textfile', { needs: [ 'fs' ], options: { directory: '/var/prometheus' }, paths: [ '{directory}' ] });
export const WIREGUARD = collector('wireguard', { needs: [ 'ubus', 'uci' ], configs: [ 'network' ] });
export const NFT = collector('nft-counters', { needs: [ 'exec' ], commands: [ 'nft' ] });
export const SAMPLER = collector('sampler', { needs: [], options: { retries: 3, verbose: false, label: 'x' } });
export const FAILING = collector('openwrt', { needs: [] }, () => Result.err('UBUS_CALL_FAILED', 'system board: Not found'));
export const IDLE = collector('dnsmasq', { needs: [] }, () => Result.none('dnsmasq is disabled'));
export const ALL = [ LOADAVG, WIFI, TEXTFILE, WIREGUARD, NFT, SAMPLER ];

// apk's file lists: loadavg in the base package, wifi and textfile in their own.
export const LISTS = {
	[`${APK}/${PACKAGE}.list`]: `/usr/bin/${NAME}\n${DIR}/loadavg.uc\n`,
	[`${APK}/${PACKAGE}-wifi.list`]: `${DIR}/wifi.uc\n`,
	[`${APK}/${PACKAGE}-textfile.list`]: `${DIR}/textfile.uc\n`,
};

// A filesystem of these regular files and apk lists; glob matches the lists and
// the start links of `links`.
export function filesystem(files, links) {
	return {
		stat: (p) => (p in (files ?? [])) ? { type: 'file' } : null,
		readfile: (p) => LISTS[p],
		glob: function(pattern) {
			if (pattern == `${APK}/${PACKAGE}*.list`)
				return sort(keys(LISTS));
			if (pattern == `${rpc.RC_DIR}/S*${NAME}`)
				return links ?? [];
			die(`unexpected glob ${pattern}`);
		},
	};
};

// A sys over the mocks: `own` is the exporter's config, cfg.ubus the ubus mock's,
// cfg.files and cfg.links what the filesystem has.
export function with_sys(own, cfg, cb) {
	with_mods({ uci: { data: { [NAME]: own, network: {} } }, ubus: cfg.ubus ?? {} }, function(mods) {
		let quiet = () => null;
		let tick = 0;
		let sys = {
			uci: mods.uci.cursor(),
			fs: filesystem(cfg.files, cfg.links),
			path: jail.PATH,
			dir: DIR,
			apk: APK,
			collectors: cfg.collectors ?? ALL,
			skipped: cfg.skipped ?? [],
			env: {
				session: () => deps.session({ ...mods, log: quiet }),
				// 5 ms a reading: a run reads it twice in a row.
				clock: () => [ 0, (tick++) * 5000000 ],
				log: quiet,
			},
			ubus: deps.ubus_channel(mods.ubus.connect),
			ledger: cfg.ledger,
		};

		cb(sys);
		sys.ubus.close();
	});
};

export function entry(sys, name) {
	return filter(rpc.collectors(sys).collectors, (c) => c.name == name)[0];
};
