'use strict';

// The generator against the real checkout: its notes agree with the code, and
// each check it makes of them refuses what it is for.

import { describe, it, assert, contains } from 'utest';
import * as fs from 'fs';
import * as main from 'docs_gen.main';
import * as harvest from 'docs_gen.harvest';
import * as pages from 'docs_gen.pages';
import * as cli from 'prometheus_exporter.cli';

const NOTES = main.load_notes(`${fs.getcwd()}/${main.NOTES}`);
const LOADED = main.load_collectors(fs, []);
const RUN = main.run(fs, NOTES, LOADED);

// The notes with `change` made to a copy of them.
function notes_with(change) {
	let n = json(sprintf('%J', NOTES));

	// json() drops the functions of metric_patterns and family_notes: keep them.
	n.metric_patterns = { ...NOTES.metric_patterns };
	n.family_notes = { ...NOTES.family_notes };
	change(n);
	return n;
}

function problems_with(change) {
	return main.run(fs, notes_with(change), LOADED).problems;
}

describe('docs_gen.main.run', () => {
	it('finds the notes and the code in agreement', () => {
		assert.match([], RUN.problems);
	});

	it('writes the six pages', () => {
		assert.match([ 'docs/reference/collectors.md', 'docs/reference/command.md', 'docs/reference/error-codes.md', 'docs/reference/metrics.md',
			'docs/reference/migration.md', 'docs/reference/uci-config.md' ], sort(keys(RUN.pages)));
	});

	it('writes the command\'s usage as it is, and a section for each of its commands', () => {
		let page = RUN.pages['docs/reference/command.md'];

		assert.match(true, index(page, '```\n' + trim(cli.USAGE) + '\n```') >= 0);
		for (let cmd in [ 'scrape', 'check', 'collector list', 'collector check', 'hash-password' ])
			assert.match(true, index(page, `## \`prometheus-exporter ${cmd}\``) >= 0, cmd);
	});

	it('takes the commands of a usage from its Usage: section', () => {
		assert.match([ 'scrape', 'collector list', 'collector check' ], pages.usage_commands(
			'x.\n\nUsage:\n  p scrape [<c>...]\n  p collector list\n  p collector check <path>\n  p -h | --help\n\nCommands:\n  other  Not one.\n'));
	});

	it('refuses a command of the usage the notes do not explain, and one the usage lacks', () => {
		let notes = { ...NOTES, command: { ...NOTES.command, commands: { ...NOTES.command.commands, 'gone': { does: 'x', exit: [] } } } };

		delete notes.command.commands['hash-password'];
		assert.match([ 'command: say what `hash-password` does', 'command: the usage has no `gone`' ],
			pages.command_page({ notes, usage: cli.USAGE }).problems);
	});

	it('documents every collector, in the collectors and the metrics', () => {
		for (let c in LOADED) {
			let anchor = `{#${c.meta.name}}`;

			assert.match(true, index(RUN.pages['docs/reference/collectors.md'], anchor) >= 0, c.meta.name);
			assert.match(true, index(RUN.pages['docs/reference/metrics.md'], anchor) >= 0, c.meta.name);
		}
	});

	it('names no device of the fixtures', () => {
		for (let path, text in RUN.pages)
			for (let set in harvest.sets(fs, harvest.ROOT))
				if (set != 'synthetic')
					assert.match(-1, index(text, set), `${path} names ${set}`);
	});

	it('refuses a collector the notes say has nothing to observe whose code never says so', () => {
		assert.match(contains([ "nothing_to_observe: cpu's code never answers nothing to observe" ]),
			problems_with((n) => { n.nothing_to_observe.cpu = { when: 'x', failure: 'y' }; }));
	});

	it('refuses a collector that can have nothing to observe and is not in the notes', () => {
		assert.match(contains([ 'nothing_to_observe: wifi can answer nothing to observe; say when' ]),
			problems_with((n) => { delete n.nothing_to_observe.wifi; }));
	});

	it('refuses a reason the code never gives', () => {
		assert.match(contains([ "nothing_to_observe: wifi's code never gives the reason 'no radio at all'" ]),
			problems_with((n) => { n.nothing_to_observe.wifi.reasons = [ 'no radio at all' ]; }));
	});

	it('refuses a family listed by hand that the fixtures show', () => {
		assert.match(contains([ "unharvested: the fixtures show thermal's node_thermal_zone_temp; take it out of the notes" ]),
			problems_with((n) => { push(n.unharvested.thermal, { name: 'node_thermal_zone_temp', labels: [], why: 'x' }); }));
	});

	it('refuses a declared family that no fixture shows and the notes do not list', () => {
		assert.match(contains([ 'thermal declares node_thermal_zone_passive_celsius, which no fixture set makes it write: add a fixture, or list it in unharvested' ]),
			problems_with((n) => { delete n.unharvested.thermal; }));
	});

	it('refuses an error code errors.uc lacks, and one it has that the notes do not explain', () => {
		let p = problems_with((n) => { n.errors.NO_SUCH = 'x'; delete n.errors.COMMAND_TIMEOUT; });

		assert.match(contains([ 'errors: say what COMMAND_TIMEOUT means', 'errors: errors.uc has no NO_SUCH' ]), p);
	});

	it('refuses a code in a section that errors.uc lacks, and one of errors.uc in no section', () => {
		let p = problems_with((n) => { push(n.error_groups[0].codes, 'NO_SUCH'); n.error_groups[1].codes = [ 'FILE_UNWRITABLE' ]; });

		assert.match(contains([ 'error_groups: errors.uc has no NO_SUCH', 'error_groups: put CONFIG_INVALID in a group' ]), p);
	});

	it('refuses a fixture set without a name, and a name for no set', () => {
		let p = problems_with((n) => { delete n.capture_sets.synthetic; n.capture_sets.nowhere = 'x'; });

		assert.match(contains([ 'capture_sets: name the fixture set synthetic', 'capture_sets: there is no fixture set nowhere' ]), p);
	});

	it('refuses a pattern that takes no family', () => {
		let p = problems_with((n) => {
			n.metric_patterns = { ...n.metric_patterns, cpu: [ { name: 'node_nothing_<x>', help: 'x', match: (f) => f == 'node_nothing' } ] };
		});

		assert.match(contains([ 'metric_patterns: cpu: node_nothing_<x> takes no family the fixtures show' ]), p);
	});
});

describe('docs_gen.main.stale', () => {
	it('lists the pages whose file holds other text', () => {
		let pages = { 'docs/reference/uci-config.md': fs.readfile('docs/reference/uci-config.md'), 'docs/reference/error-codes.md': 'x' };

		assert.match([ 'docs/reference/error-codes.md' ], main.stale(fs, pages));
	});
});
