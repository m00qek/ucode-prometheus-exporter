'use strict';

// What every collector in src/ owes the repository: a valid meta, a unit test,
// and a package whose dependencies cover its needs and commands.

import { describe, it, assert } from 'utest';
import { readfile, lsdir } from 'fs';
import * as loader from 'node_exporter.loader';

const SOURCES = 'src/node_exporter/collectors';
const MAKEFILE = readfile('openwrt/prometheus-node-exporter-ucode/Makefile');

// The package each need or command calls for; `null` for what the base package has.
const NEED_PACKAGES = { fs: null, ubus: null, uci: null, rtnl: null, time: null, exec: null, log: null, nl80211: '+ucode-mod-nl80211' };
const COMMAND_PACKAGES = { nft: '+nftables-json', mmcli: '+modemmanager', 'ubnt-manager': '+ubnt-manager', ethtool: '+ethtool' };

const IDS = sort(map(filter(lsdir(SOURCES), (f) => match(f, /\.uc$/)), (f) => substr(f, 0, -3)));

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

		it('has a unit test', () => {
			assert.match(true, readfile(`test/unit/node_exporter/collectors/${id}_test.uc`) != null,
				`add test/unit/node_exporter/collectors/${id}_test.uc`);
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
			for (let cmd in mod.meta.commands ?? [])
				push(wanted, COMMAND_PACKAGES[cmd] ?? `a package for '${cmd}'`);

			if (!sub)
				assert.match([], wanted, `${id} is a base collector, so it can need nothing more than the base package`);
			else
				assert.match([], filter(wanted, (p) => !(p in sub.depends)), `${id}: missing from its DEPENDS`);
		});
	});
}

describe('collectors', () => {
	it('are there', () => {
		assert.match(true, length(IDS) > 0);
	});

	for (let id in IDS)
		checks(id);
});
