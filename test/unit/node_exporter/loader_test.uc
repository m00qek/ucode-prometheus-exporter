'use strict';

import { describe, it, prop, gen, assert, mock, regex } from 'utest';
import * as loader from 'node_exporter.loader';
import * as Result from 'node_exporter.result';

const OK = () => Result.ok();

function module_named(name, extra) {
	return { meta: { name, help: 'Something.', needs: [], ...(extra ?? {}) }, collect: OK };
}

function problem(id, mod) {
	let res = loader.validate(id, mod);
	return res.ok ? null : res.details;
}

describe('loader.id_of', () => {
	it('makes a name a module name', () => {
		assert.match([ 'ltq_dsl', 'realtek_poe', 'cpu' ], map([ 'ltq-dsl', 'realtek-poe', 'cpu' ], loader.id_of));
	});

	prop('never leaves a hyphen', gen.string({ charset: 'ab-_', min_len: 0, max_len: 10 }), (s) => {
		assert.match(-1, index(loader.id_of(s), '-'));
	});
});

describe('loader.validate', () => {
	it('accepts a well-formed module and defaults its options', () => {
		let res = loader.validate('ltq_dsl', module_named('ltq-dsl', { needs: [ 'ubus' ] }));

		assert.match(true, res.ok);
		assert.match({ name: 'ltq-dsl', help: 'Something.', needs: [ 'ubus' ], options: {} }, res.data.meta);
		assert.match('ltq_dsl', res.data.id);
	});

	it('says what is wrong with a malformed one', () => {
		assert.match([
			'x: exports no meta',
			"x: meta.name must be 'x', or it with '-' for '_'",
			"x: meta.name must be 'x', or it with '-' for '_'",
			'x: meta.help must be a sentence',
			'x: meta.needs must list capabilities once each',
			"x: unknown need 'network'",
			'x: meta.configs must list the uci configs it reads',
			"x: meta.configs cannot name 'prometheus-node-exporter-ucode'; its own options come as options",
			'x: meta.configs without uci in meta.needs',
			'x: meta.commands must list the programs exec runs',
			'x: meta.commands without exec in meta.needs',
			"x: option 'enabled' is the core's, every collector has it",
			"x: option 'stations' needs a boolean, integer or string default",
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths without fs, socket or exec in meta.needs',
			'x: meta.paths: {dir} is not a string option',
			'x: meta.paths: {n} is not a string option',
			'x: meta.paths: "relative" is not an absolute path',
			'x: meta.paths: /var/run is too broad to mount for one collector',
			'x: meta.paths: /tmp is too broad to mount for one collector',
			'x: exports no collect function',
		], [
			problem('x', {}),
			problem('x', module_named('y')),
			problem('x', module_named('X')),
			problem('x', module_named('x', { help: '' })),
			problem('x', module_named('x', { needs: [ 'fs', 'fs' ] })),
			problem('x', module_named('x', { needs: [ 'network' ] })),
			problem('x', module_named('x', { needs: [ 'uci' ] })),
			problem('x', module_named('x', { needs: [ 'uci' ], configs: [ 'prometheus-node-exporter-ucode' ] })),
			problem('x', module_named('x', { configs: [ 'dhcp' ] })),
			problem('x', module_named('x', { needs: [ 'exec' ] })),
			problem('x', module_named('x', { commands: [ 'nft' ] })),
			problem('x', module_named('x', { options: { enabled: true } })),
			problem('x', module_named('x', { options: { stations: null } })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: '/var/x' })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ 7 ] })),
			problem('x', module_named('x', { needs: [ 'ubus' ], paths: [ '/var/x' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ '{dir}' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], options: { n: 1 }, paths: [ '/var/{n}' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ 'relative' ] })),
			problem('x', module_named('x', { needs: [ 'socket' ], paths: [ '/var/run' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], options: { dir: '/tmp' }, paths: [ '{dir}' ] })),
			problem('x', { meta: module_named('x').meta }),
		]);
	});

	it('takes paths, {option}s of string options filled with their defaults, and functions', () => {
		let res = loader.validate('x', module_named('x', {
			needs: [ 'fs', 'exec' ], commands: [ 'mmcli' ],
			options: { directory: '/var/prometheus' },
			paths: [ '/var/run/dbus', '{directory}', (options) => [ options.directory ] ],
		}));

		assert.match([ true, 3 ], [ res.ok, length(res.data.meta.paths) ]);
	});
});

describe('loader.discover and load', () => {
	const DIR = '/usr/share/ucode/node_exporter/collectors';
	const FILES = { [DIR + '/b.uc']: '', [DIR + '/a.uc']: '', [DIR + '/broken.uc']: '', [DIR + '/odd.uc']: '', [DIR + '/README']: '' };

	it('fingerprints the collector files, so any change to them shows', () => {
		mock.inject('fs', { strict: true, data: { [DIR + '/a.uc']: 'x', [DIR + '/README']: '' } }, (fs) => {
			let before = loader.fingerprint(fs, DIR);

			assert.match(before, loader.fingerprint(fs, DIR));
			fs.writefile(DIR + '/notes.txt', 'not a collector');
			assert.match(before, loader.fingerprint(fs, DIR));
			fs.writefile(DIR + '/a.uc', 'xy');
			assert.match(true, loader.fingerprint(fs, DIR) != before, 'a replaced file');
			fs.writefile(DIR + '/a.uc', 'x');
			fs.writefile(DIR + '/b.uc', '');
			assert.match(true, loader.fingerprint(fs, DIR) != before, 'an added file');
			fs.unlink(DIR + '/b.uc');
			assert.match(before, loader.fingerprint(fs, DIR));
		});
	});

	it('finds the modules of a directory, sorted', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			assert.match([ 'a', 'b', 'broken', 'odd' ], loader.discover(fs, DIR));
		});
	});

	it('loads the valid ones and logs the rest', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			let logs = [];
			let mods = { a: module_named('a'), b: module_named('b'), odd: { meta: 1 } };
			let loaded = loader.load(fs, DIR, (id) => mods[id] ?? die(`Unable to compile module\nmore`), (m) => push(logs, m));

			assert.match([ 'a', 'b' ], map(loaded, (c) => c.meta.name));
			assert.match([
				"cannot load collector 'broken': Unable to compile module",
				'skipping collector: COLLECTOR_INVALID (odd: exports no meta)',
			], logs);
		});
	});

	it('imports a collector module by its name', () => {
		assert.match('loadavg', loader.import_module('loadavg').meta.name);
		assert.throws(() => loader.import_module('does_not_exist'), regex(/Unable to/));
	});
});
