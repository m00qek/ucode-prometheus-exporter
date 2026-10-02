'use strict';

// What every collector in src/ owes the repository: a valid meta, a section in
// the generated reference (make docs-gen), a unit test, and a package whose
// dependencies cover its needs and commands.

import { describe, it, assert } from 'utest';
import { readfile, lsdir, popen } from 'fs';
import * as loader from 'prometheus_exporter.loader';

const SOURCES = 'src/prometheus_exporter/collectors';
const MAKEFILE = readfile('openwrt/ucode-prometheus-exporter/Makefile');
const REFERENCE = readfile('docs/reference/collectors.md');

// The package each need or command calls for; `null` for what the base package has.
const NEED_PACKAGES = { fs: null, ubus: null, uci: null, rtnl: null, time: null, exec: null, log: null, nl80211: '+ucode-mod-nl80211', socket: '+ucode-mod-socket' };
const COMMAND_PACKAGES = { nft: '+nftables-json', mmcli: '+modemmanager', 'ubnt-manager': '+ubnt-manager', ethtool: '+ethtool', tc: '+tc', chronyc: '+chrony' };

const IDS = sort(map(filter(lsdir(SOURCES), (f) => match(f, /\.uc$/)), (f) => substr(f, 0, -3)));

describe('loader.OWN', () => {
	it('names every collector of the source tree, and nothing else', () => {
		assert.match(IDS, sort([ ...loader.OWN ]));
	});
});

function base_collectors() {
	return split(trim(match(MAKEFILE, /\nBASE_COLLECTORS:=([^\n]*)/)[1]), /\s+/);
}

// { name, depends } of the Collector line for module `id`, or null.
function subpackage(id) {
	for (let line in split(MAKEFILE, '\n')) {
		let m = match(line, /^\$\(eval \$\(call Collector,([^,]*),([^,]*),[^,]*,(.*)\)\)$/);
		if (m && m[1] == id)
			return { name: m[2], depends: filter(split(trim(m[3]), /\s+/), length) };
	}
	return null;
}

// A function per collector: callbacks made in a loop body would all see its last id.
function checks(id) {
	describe(id, () => {
		let mod = loader.import_module(id);

		it('exports a valid meta and collect', () => {
			let res = loader.validate(id, mod);
			assert.match(true, res.ok, res.details);
		});

		it('is in the generated reference', () => {
			let heading = `## \`${mod.meta.name}\` {#${mod.meta.name}}`;
			assert.match(true, index(REFERENCE, heading) >= 0, `run make docs-gen: docs/reference/collectors.md has no ${mod.meta.name}`);
		});

		it('has a unit test', () => {
			assert.match(true, readfile(`test/unit/prometheus_exporter/collectors/${id}_test.uc`) != null,
				`add test/unit/prometheus_exporter/collectors/${id}_test.uc`);
		});

		it('is packaged once: in the base package or as its own, named after it', () => {
			let base = id in base_collectors();
			let sub = subpackage(id);

			assert.match(true, base != (sub != null), `${id}: base ${base}, subpackage ${sub?.name}`);
			if (sub)
				assert.match(mod.meta.name, sub.name);
		});

		// A subpackage may depend on more: the package of a ubus service it reads.
		it('depends on the packages its needs and commands call for', () => {
			let sub = subpackage(id);
			let wanted = [];

			for (let need in mod.meta.needs)
				if (NEED_PACKAGES[need])
					push(wanted, NEED_PACKAGES[need]);
			// An optional command is run only where it is installed.
			for (let cmd in mod.meta.commands ?? [])
				if (!(cmd in (mod.meta.optional_commands ?? [])))
					push(wanted, COMMAND_PACKAGES[cmd] ?? `a package for '${cmd}'`);

			if (!sub)
				assert.match([], wanted, `${id} is a base collector, so it can need nothing more than the base package`);
			else
				assert.match([], filter(wanted, (p) => !(p in sub.depends)), `${id}: missing from its DEPENDS`);
		});
	});
}

// The group packages: { name, members }, members by collector name.
function groups() {
	let p = popen('devenv/scripts/package-info.sh groups', 'r');
	let out = p.read('all');
	p.close();

	return map(filter(split(out, '\n'), length), (l) => {
		let w = split(l, ' ');
		return { name: w[0], members: slice(w, 1) };
	});
}

describe('groups', () => {
	it('are there', () => {
		assert.match([ 'full', 'hardware', 'network', 'wireless' ], sort(map(groups(), (g) => g.name)));
	});

	it('are made of collector subpackages, each once', () => {
		let subpackages = map(IDS, (id) => subpackage(id)?.name);

		for (let g in groups()) {
			assert.match([], filter(g.members, (m) => !(m in subpackages)), `${g.name}: not a collector subpackage`);
			assert.match(length(uniq(g.members)), length(g.members), `${g.name}: a collector twice`);
		}
	});
});

describe('collectors', () => {
	it('are there', () => {
		assert.match(true, length(IDS) > 0);
	});

	for (let id in IDS)
		checks(id);
});

// wifi and wifi_stations on the access point's captures: wifi_stations yields
// its station families to wifi (meta.yields), so each station is exported once.
describe('wifi beside wifi_stations', () => {
	it('exports each station once, by wifi, and fails neither', () => {
		let fixtures = loadstring("import * as f from 'docs_gen.fixtures'; return f;", { raw_mode: true })();
		let scrape = loadstring("import * as s from 'prometheus_exporter.scrape'; return s;", { raw_mode: true })();
		let deps = loadstring("import * as d from 'prometheus_exporter.deps'; return d;", { raw_mode: true })();
		let wifi = loader.validate('wifi', loader.import_module('wifi')).data;
		let stations = loader.validate('wifi_stations', loader.import_module('wifi_stations')).data;
		let mods = fixtures.modules('test/fixtures/caju-ap', {});
		let logs = [];
		let env = { session: () => deps.session({ ...mods, log: () => null }), clock: () => [ 0, 0 ], log: (l, m) => push(logs, m), version: 'dev' };
		let body = split(scrape.scrape(env, [ wifi, stations ], '').body, '\n');
		let signals = filter(body, (l) => index(l, 'node_wifi_station_signal_dbm{') == 0);

		assert.match([], logs);
		assert.match(true, 'node_scrape_collector_success{collector="wifi"} 1' in body);
		assert.match(true, 'node_scrape_collector_success{collector="wifi_stations"} 1' in body);
		assert.match(true, length(signals) > 0);
		assert.match([], filter(signals, (l) => index(l, 'radio="') < 0));
	});
});
