'use strict';

// The migration page against the real checkout: its mapping agrees with the
// feed's exporters and the collectors, and each check it makes refuses what
// it is for.

import { describe, it, assert } from 'utest';
import * as fs from 'fs';
import * as main from 'docs_gen.main';
import * as migration from 'docs_gen.migration';

const GATHERED = main.context(fs, main.load_notes(`${fs.getcwd()}/${main.NOTES}`), main.load_collectors(fs, []));
const CTX = GATHERED.ctx;
const PAGE = migration.migration_page(CTX);

// The page of a copy of the inputs, `change` made to it: { notes, inventory,
// template }.
function page_with(change) {
	let m = json(sprintf('%J', { notes: { ...CTX.migration.notes }, inventory: CTX.migration.inventory, template: CTX.migration.template }));

	change(m);
	return migration.migration_page({ ...CTX, migration: m });
}

describe('docs_gen.migration.migration_page', () => {
	it('finds the mapping, the feed\'s exporters and the collectors in agreement', () => {
		assert.match([], PAGE.problems);
	});

	it('fills every place of the text', () => {
		assert.match(false, match(PAGE.text, /\{\{[a-z]+\}\}/) != null);
	});

	it('refuses a family of the feed\'s the mapping does not map', () => {
		let res = page_with((m) => delete m.notes.families['node_load1']);

		assert.match(true, 'migration: lua loadavg writes node_load1, which docs/gen/migration.uc does not map' in res.problems);
	});

	it('refuses a mapping of a family neither feed exporter writes', () => {
		let res = page_with((m) => m.notes.families['node_gone'] = { labels: [], to: 'node_load1' });

		assert.match(true, 'migration: neither feed exporter writes node_gone: take it out of docs/gen/migration.uc' in res.problems);
	});

	it('refuses a label the collector\'s source has no key for', () => {
		let res = page_with((m) => m.notes.families['node_nat_traffic'].labels = [ 'src', 'dst' ]);

		assert.match(true, 'migration: lua nat_traffic: node_nat_traffic: its source has no label dst' in res.problems);
	});

	it('refuses a mapping to a family no collector writes', () => {
		let res = page_with((m) => m.notes.families['node_load1'].to = 'node_load_one');

		assert.match(true, 'migration: node_load1: this exporter writes no node_load_one' in res.problems);
	});

	it('refuses a place of the text it does not fill', () => {
		let res = page_with((m) => m.template += '\n{{nothing}}\n');

		assert.match(true, 'migration: docs/gen/migration.md has {{nothing}}, which the generator does not fill' in res.problems);
	});

	it('renames in the relabeling only what keeps its labels', () => {
		assert.match(true, index(PAGE.text, '    regex: node_procs_running_total\n    target_label: __name__\n    replacement: node_procs_running') >= 0);
		assert.match(true, index(PAGE.text, 'regex: uci_dhcp_host\n') < 0);
	});
});

describe('docs_gen.migration.resolve', () => {
	const ours = { node_load1: { labels: [] }, dnsmasq_dns_queries_forwarded_total: { labels: [] }, dnsmasq_bootp_total: { labels: [] } };

	it('takes a family by its name', () => {
		assert.match([ ours.node_load1 ], migration.resolve(ours, 'node_load1'));
	});

	it('takes the families a name with <...> parts matches', () => {
		assert.match(2, length(migration.resolve(ours, 'dnsmasq_<key>_total')));
		assert.match([], migration.resolve(ours, 'node_load2'));
	});
});
