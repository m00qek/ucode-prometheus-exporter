'use strict';

import { describe, it, prop, gen, assert, mock, regex, contains } from 'utest';
import * as loader from 'prometheus_exporter.loader';
import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as collection from 'prometheus_exporter.collection';

const OK = () => Result.ok();

function module_named(name, extra) {
	return { meta: { name, title: 'Some thing', help: 'Something.', needs: [], ...(extra ?? {}) }, collect: OK };
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
		let res = loader.validate('ltq_dsl', module_named('ltq-dsl', { needs: [ 'ubus' ], ubus: { dsl: [ 'metrics' ] } }));

		assert.match(true, res.ok);
		assert.match({ name: 'ltq-dsl', title: 'Some thing', help: 'Something.', needs: [ 'ubus' ], ubus: { dsl: [ 'metrics' ] }, options: {} }, res.data.meta);
		assert.match('ltq_dsl', res.data.id);
	});

	it('says what is wrong with a malformed one', () => {
		assert.match([
			'x: exports no meta',
			"x: meta.name must be 'x', or it with '-' for '_'",
			"x: meta.name must be 'x', or it with '-' for '_'",
			'x: meta.title must be a label of 1 to 40 characters',
			'x: meta.title must be a label of 1 to 40 characters',
			'x: meta.title must be a label of 1 to 40 characters',
			'x: meta.help must be a sentence',
			'x: meta.needs must list capabilities once each',
			"x: unknown need 'network'",
			'x: meta.configs must list the uci configs it reads',
			"x: meta.configs cannot name 'prometheus-exporter'; its own options come as options",
			'x: meta.configs without uci in meta.needs',
			'x: meta.commands must list the programs exec runs',
			'x: meta.commands without exec in meta.needs',
			'x: meta.optional_commands must list some of meta.commands',
			'x: meta.optional_commands must list some of meta.commands',
			'x: meta.optional_commands must list some of meta.commands',
			'x: meta.timeout without exec in meta.needs',
			'x: meta.timeout must be the seconds its commands may take, 1 to 30',
			'x: meta.timeout must be the seconds its commands may take, 1 to 30',
			'x: meta.timeout must be the seconds its commands may take, 1 to 30',
			"x: option 'enabled' is the core's, every collector has it",
			"x: option 'timeout' is the core's, every collector that runs programs has it; meta.timeout sets its default",
			"x: option 'timeout' is the core's, every collector that runs programs has it; meta.timeout sets its default",
			"x: option 'stations' must be { default, title, help, datatype }",
			"x: option 'stations' needs a boolean, integer or string default",
			"x: option 'stations' needs a title of 1 to 40 characters",
			"x: option 'stations' needs a title of 1 to 40 characters",
			"x: option 'stations' needs a title of 1 to 40 characters",
			"x: option 'stations' needs a title of 1 to 40 characters",
			"x: option 'stations' needs a help sentence",
			"x: option 'stations' has 'deafult', not one of default, title, help, datatype",
			"x: option 'Stations' needs a name of a-z, 0-9 and _",
			'x: option \'dir\': unknown datatype "dir"',
			"x: option 'dir': datatype directory does not take a int",
			"x: option 'dir': its default is not an absolute path",
			"x: option 'n': its default is not an integer from 1 to 9",
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths must list paths, or functions that give them',
			'x: meta.paths: an owned path is { path, owned: true }',
			'x: meta.paths: an owned path is { path, owned: true }',
			'x: meta.paths: an owned path is { path, owned: true }',
			'x: meta.paths: an owned path is { path, owned: true }',
			'x: meta.paths: /tmp is too broad to mount for one collector',
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
			problem('x', module_named('x', { title: null })),
			problem('x', module_named('x', { title: '' })),
			problem('x', module_named('x', { title: 'A title much longer than forty characters' })),
			problem('x', module_named('x', { help: '' })),
			problem('x', module_named('x', { needs: [ 'fs', 'fs' ] })),
			problem('x', module_named('x', { needs: [ 'network' ] })),
			problem('x', module_named('x', { needs: [ 'uci' ] })),
			problem('x', module_named('x', { needs: [ 'uci' ], configs: [ 'prometheus-exporter' ] })),
			problem('x', module_named('x', { configs: [ 'dhcp' ] })),
			problem('x', module_named('x', { needs: [ 'exec' ] })),
			problem('x', module_named('x', { commands: [ 'nft' ] })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], optional_commands: [ 'chronyc' ] })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], optional_commands: 'nft' })),
			problem('x', module_named('x', { optional_commands: [ 'nft' ] })),
			problem('x', module_named('x', { timeout: 10 })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], timeout: 0 })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], timeout: 31 })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], timeout: 2.5 })),
			problem('x', module_named('x', { options: { enabled: { default: true, title: 'T', help: 'H.' } } })),
			problem('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft' ], options: { timeout: { default: 9, title: 'T', help: 'H.' } } })),
			problem('x', module_named('x', { options: { timeout: { default: 'soon', title: 'T', help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: true } })),
			problem('x', module_named('x', { options: { stations: { default: null, title: 'T', help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: { default: true, help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: { default: true, title: '', help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: { default: true, title: 'A title much longer than forty characters', help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: { default: true, title: 'Two\nlines', help: 'H.' } } })),
			problem('x', module_named('x', { options: { stations: { default: true, title: 'T' } } })),
			problem('x', module_named('x', { options: { stations: { deafult: true, help: 'H.' } } })),
			problem('x', module_named('x', { options: { Stations: { default: true, title: 'T', help: 'H.' } } })),
			problem('x', module_named('x', { options: { dir: { default: '/x', title: 'T', help: 'H.', datatype: 'dir' } } })),
			problem('x', module_named('x', { options: { dir: { default: 1, title: 'T', help: 'H.', datatype: 'directory' } } })),
			problem('x', module_named('x', { options: { dir: { default: 'x', title: 'T', help: 'H.', datatype: 'directory' } } })),
			problem('x', module_named('x', { options: { n: { default: 0, title: 'T', help: 'H.', datatype: 'range(1,9)' } } })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: '/var/x' })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ 7 ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ { path: '/var/x' } ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ { path: '/var/x', owned: 1 } ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ { path: 7, owned: true } ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ { path: '/var/x', owned: true, mode: 0700 } ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ { path: '/tmp', owned: true } ] })),
			problem('x', module_named('x', { needs: [ 'ubus' ], ubus: { system: [ 'board' ] }, paths: [ '/var/x' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ '{dir}' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], options: { n: { default: 1, title: 'T', help: 'H.' } }, paths: [ '/var/{n}' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], paths: [ 'relative' ] })),
			problem('x', module_named('x', { needs: [ 'socket' ], paths: [ '/var/run' ] })),
			problem('x', module_named('x', { needs: [ 'fs' ], options: { dir: { default: '/tmp', title: 'T', help: 'H.' } }, paths: [ '{dir}' ] })),
			problem('x', { meta: module_named('x').meta }),
		]);
	});

	it('takes paths, {option}s of string options filled with their defaults, and functions', () => {
		let res = loader.validate('x', module_named('x', {
			needs: [ 'fs', 'exec' ], commands: [ 'mmcli' ],
			options: { directory: { default: '/var/prometheus', title: 'T', help: 'Where.', datatype: 'directory' } },
			paths: [ '/var/run/dbus', '{directory}', (options) => [ options.directory ] ],
		}));

		assert.match([ true, 3 ], [ res.ok, length(res.data.meta.paths) ]);
	});

	it('takes meta.optional_commands, some of its commands', () => {
		let res = loader.validate('x', module_named('x', { needs: [ 'exec' ], commands: [ 'nft', 'chronyc' ], optional_commands: [ 'chronyc' ] }));

		assert.match([ true, [ 'chronyc' ] ], [ res.ok, res.data.meta.optional_commands ]);
	});

	it('takes meta.timeout, the seconds an exec collector\'s commands get', () => {
		let res = loader.validate('x', module_named('x', { needs: [ 'exec' ], commands: [ 'ssh' ], timeout: loader.TIMEOUT_MAX }));

		assert.match([ true, 30 ], [ res.ok, res.data.meta.timeout ]);
	});

	prop('refuses every option name the core reserves, whatever the collector needs',
		gen.tuple(gen.elements(...config.RESERVED), gen.elements([], [ 'fs' ], [ 'exec' ])), (t) => {
			let needs = t[1];
			let extra = ('exec' in needs) ? { commands: [ 'nft' ] } : {};
			let res = loader.validate('x', module_named('x', { needs, ...extra, options: { [t[0]]: { default: 1, title: 'T', help: 'H.' } } }));

			assert.match([ false, true ], [ res.ok, index(res.details, `option '${t[0]}' is the core's`) >= 0 ]);
		});

	it('caps meta.timeout as the main section caps exec_timeout', () => {
		assert.match(config.EXEC_TIMEOUT_MAX, loader.TIMEOUT_MAX);
	});

	it('takes options declared as { default, title, help, datatype }', () => {
		let options = {
			stations: { default: true, title: 'Station metrics', help: 'Per-station metrics.' },
			fields: { default: '^pg', title: 'Fields', help: 'A regex.', datatype: 'regex' },
			port: { default: 9100, title: 'A title of exactly forty characters, ok.', help: 'A port.', datatype: 'range(1,65535)' },
		};
		let res = loader.validate('x', module_named('x', { options }));

		assert.match([ true, options ], [ res.ok, res.data.meta.options ]);
	});

	it('takes a cost of light or heavy, and nothing else', () => {
		assert.match([ true, true, true ], map([ null, 'light', 'heavy' ], (cost) => loader.validate('x', module_named('x', { cost })).ok));
		assert.match('x: meta.cost must be one of light, heavy', problem('x', module_named('x', { cost: 5 })));
	});

	it('takes max_samples of 1 up to the most the core allows', () => {
		assert.match(true, loader.validate('x', module_named('x', { max_samples: 65536 })).ok);
		for (let n in [ 0, config.MAX_SAMPLES_MAX + 1, '10', 1.5 ])
			assert.match(`x: meta.max_samples must be the samples it may write, 1 to ${config.MAX_SAMPLES_MAX}`,
				problem('x', module_named('x', { max_samples: n })), n);
	});

	prop('takes any title of 1 to 40 characters', gen.string({ charset: 'abc XYZ-', min_len: 1, max_len: 40 }), (title) => {
		assert.match(true, loader.validate('x', module_named('x', { title })).ok);
	});
});

describe('loader.is_strict', () => {
	it('takes a module whose first statement is the directive, after comments, blank lines and #!', () => {
		for (let text in [
			"'use strict';\n",
			'"use strict";\nexport const x = 1;',
			"'use strict'\nexport const x = 1;",
			"// A collector.\n\n/* Of things. */\n'use strict';\n",
			"#!/usr/bin/ucode\n'use strict';\n",
			"'use strict'",
		])
			assert.match(true, loader.is_strict(text), text);
	});

	it('reads comments and blank space longer than the window it looks in first', () => {
		let long = '', blank = '';

		for (let i = 0; i < 3000; i++) {
			long += 'x';
			blank += ' ';
		}

		for (let text in [
			`/* ${long} */\n'use strict';\n${long}\n`,
			`// ${long}\n'use strict';\n`,
			`${blank}\n'use strict';\n`,
			`/* a */\n/* ${long}\n${long} */ 'use strict';\n`,
		])
			assert.match(true, loader.is_strict(text), substr(text, 0, 20));

		assert.match([ false, false ], [ loader.is_strict(`/* ${long}\n'use strict';\n`), loader.is_strict(`/* ${long} */ x;\n'use strict';\n`) ]);
	});

	it('refuses one without it first, or where it is not a statement of its own', () => {
		for (let text in [
			'',
			"export const x = 1;\n'use strict';\n",
			"'use strict' + 1;\n",
			"'use  strict';\n",
			"/* unterminated\n'use strict';\n",
			"'use strictly';\n",
			null,
		])
			assert.match(false, loader.is_strict(text), text);
	});

	prop('is strict whatever comments come first', gen.array(gen.elements('// x\n', '/* y */', '\n', ' ', '/** z **/'), { min_len: 0, max_len: 5 }), (lead) => {
		assert.match(true, loader.is_strict(join('', lead) + "'use strict';\n"));
	});

	it('takes every collector of the source tree', () => {
		for (let f in require('fs').glob('src/prometheus_exporter/collectors/*.uc'))
			assert.match(true, loader.is_strict(require('fs').readfile(f)), f);
	});
});

describe('loader.import_problem', () => {
	const API = "'use strict';\nimport { Result } from 'prometheus_exporter.api';\n";

	it('takes a module that imports the collector API alone, or nothing', () => {
		assert.match([ null, null ], [ loader.import_problem(API), loader.import_problem("'use strict';\nexport const x = 1;\n") ]);
	});

	it('refuses the modules of the system, saying which capability gives what each would', () => {
		assert.match(join('; ', [
			"imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs",
			"imports ubus (line 4): a collector calls ubus through deps.ubus, with 'ubus' in meta.needs",
			"imports uci (line 5): a collector reads uci configs through deps.uci, with 'uci' in meta.needs",
			"imports socket (line 6): a collector talks to a Unix socket through deps.socket, with 'socket' in meta.needs",
			"imports rtnl (line 7): a collector asks rtnetlink through deps.rtnl, with 'rtnl' in meta.needs",
			"imports nl80211 (line 8): a collector asks nl80211 through deps.nl80211, with 'nl80211' in meta.needs",
		]), loader.import_problem(API + join('\n', map([ 'fs', 'ubus', 'uci', 'socket', 'rtnl', 'nl80211' ],
			(m) => `import * as x_${m} from '${m}';`))));
	});

	it('refuses the core\'s modules, pointing at the API for what it exports of them', () => {
		assert.match(join('; ', [
			'imports prometheus_exporter.result (line 1): take Result from prometheus_exporter.api',
			'imports prometheus_exporter.proc (line 2): take proc from prometheus_exporter.api',
			'imports prometheus_exporter.deps (line 3): a collector imports prometheus_exporter.api alone',
			'imports prometheus_exporter.collectors.loadavg (line 4): a collector imports prometheus_exporter.api alone',
		]), loader.import_problem(join('\n', [
			"import * as Result from 'prometheus_exporter.result';",
			"import { fields } from 'prometheus_exporter.proc';",
			"import * as deps from 'prometheus_exporter.deps';",
			"import { collect } from 'prometheus_exporter.collectors.loadavg';",
		])));
	});

	it('refuses the pure modules too, and code loaded past the imports', () => {
		assert.match(join('; ', [
			'imports math (line 3): a collector imports prometheus_exporter.api alone',
			"calls require(\"fs\") (line 4): a collector reads files through deps.fs, with 'fs' in meta.needs",
			'calls loadstring() (line 5): a collector imports prometheus_exporter.api alone',
		]), loader.import_problem(API + "import { abs } from 'math';\nlet fs = require('fs');\nlet f = loadstring(src);\n"));
	});

	// A program system() starts outlives the child a scrape kills under the
	// collector: three scrapes once left three sleeps running.
	it('refuses system(), pointing at deps.exec, and include(), which loads code as require() does', () => {
		assert.match(join('; ', [
			"calls system() (line 3): a collector runs programs through deps.exec, with 'exec' in meta.needs and the program in meta.commands, which kills one still running at its timeout",
			'calls include("helper.uc") (line 4): a collector imports prometheus_exporter.api alone',
		]), loader.import_problem(API + "system('sleep 3600 &');
include('helper.uc');
let s = 'system(\'x\')'; // system('y')
d.ubus.call('system', 'board');
ex.system('/proc/stat');
"));
	});

	it('is why the loader leaves a module out by its text: strict mode first, then its imports', () => {
		assert.match([
			"not in strict mode: its first statement must be 'use strict'",
			"imports fs (line 2): a collector reads files through deps.fs, with 'fs' in meta.needs",
			null,
		], [
			loader.refusal("import * as fs from 'fs';\n"),
			loader.refusal("'use strict';\nimport * as fs from 'fs';\n"),
			loader.refusal(API),
		]);
	});
});

describe('loader.discover and load', () => {
	const DIR = '/usr/share/ucode/prometheus_exporter/collectors';
	const STRICT = "'use strict';\n";
	const FILES = { [DIR + '/b.uc']: STRICT, [DIR + '/a.uc']: STRICT, [DIR + '/broken.uc']: STRICT, [DIR + '/odd.uc']: STRICT, [DIR + '/README']: '' };

	it('finds the modules of a directory, sorted', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			assert.match([ 'a', 'b', 'broken', 'odd' ], loader.discover(fs, DIR));
		});
	});

	it('loads the valid ones and logs the rest', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			let logs = [];
			let mods = { a: module_named('a'), b: module_named('b'), odd: { meta: 1 } };
			let loaded = loader.load(fs, DIR, (id) => mods[id] ?? die(`Unable to compile module\nmore`), (level, m) => push(logs, [ level, m ]));

			assert.match([ 'a', 'b' ], map(loaded, (c) => c.meta.name));
			assert.match([
				[ 'err', "cannot load collector 'broken': Unable to compile module" ],
				[ 'err', 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ],
			], logs);
		});
	});

	it('refuses a module that is not in strict mode, without loading it', () => {
		mock.inject('fs', { strict: true, data: { ...FILES, [DIR + '/b.uc']: "'use strict' + 1;\n" } }, (fs) => {
			let logs = [];
			let imported = [];
			let loaded = loader.load(fs, DIR, (id) => { push(imported, id); return module_named(id); }, (level, m) => push(logs, [ level, m ]));

			assert.match([ 'a', 'broken', 'odd' ], imported);
			assert.match(contains([ [ 'err', "skipping collector: COLLECTOR_INVALID (b: not in strict mode: its first statement must be 'use strict')" ] ]), logs);
			assert.match([ 'a', 'broken', 'odd' ], map(loaded, (c) => c.meta.name));
		});
	});

	it('refuses a module that imports anything but the collector API, without loading it', () => {
		let text = "'use strict';\nimport { Result } from 'prometheus_exporter.api';\nimport { readfile } from 'fs';\n";

		mock.inject('fs', { strict: true, data: { ...FILES, [DIR + '/b.uc']: text } }, (fs) => {
			let logs = [];
			let imported = [];
			let loaded = loader.load(fs, DIR, (id) => { push(imported, id); return module_named(id); }, (level, m) => push(logs, [ level, m ]));

			assert.match([ 'a', 'broken', 'odd' ], imported);
			assert.match(contains([ [ 'err', "skipping collector: COLLECTOR_INVALID (b: imports fs (line 3): a collector reads files through deps.fs, with 'fs' in meta.needs)" ] ]), logs);
			assert.match([ 'a', 'broken', 'odd' ], map(loaded, (c) => c.meta.name));
		});
	});

	it('loads only what the probe loaded, and says why it left the others out', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			let logs = [];
			let imported = [];
			let probed = [];
			let probe = function(ids) {
				push(probed, ...ids);
				return {
					a: { ok: true }, b: { ok: false, hung: true, error: 'still loading after 5 s: stopped' },
					broken: { ok: false, error: 'Unable to compile module' }, odd: { ok: true },
				};
			};
			let loaded = loader.load(fs, DIR, (id) => { push(imported, id); return module_named(id); }, (level, m) => push(logs, [ level, m ]), probe);

			assert.match([ 'a', 'b', 'broken', 'odd' ], probed);
			assert.match([ 'a', 'odd' ], imported);
			assert.match([ 'a', 'odd' ], map(loaded, (c) => c.meta.name));
			assert.match([
				[ 'err', "collector 'b' hung at load: still loading after 5 s: stopped; it is left out" ],
				[ 'err', "cannot load collector 'broken': Unable to compile module" ],
			], logs);
		});
	});

	it('loads every module that is to be loaded as one program, with import_all', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			let logs = [];
			let alone = [];
			let together = [];
			let probe = (ids) => ({ a: { ok: true }, b: { ok: true }, broken: { ok: false, error: 'Unable to compile module' }, odd: { ok: true, unprobed: true } });
			let import_all = function(ids) {
				push(together, ...ids);
				return { a: module_named('a'), b: module_named('b'), odd: module_named('odd') };
			};
			let loaded = loader.load(fs, DIR, (id) => { push(alone, id); return module_named(id); }, (level, m) => push(logs, [ level, m ]), probe, import_all);

			assert.match([ 'a', 'b', 'odd' ], together);
			assert.match([], alone);
			assert.match([ 'a', 'b', 'odd' ], map(loaded, (c) => c.meta.name));
			assert.match([ [ 'err', "cannot load collector 'broken': Unable to compile module" ] ], logs);
		});
	});

	it('loads each alone when they do not load as one program, and one that does not load costs itself alone', () => {
		mock.inject('fs', { strict: true, data: FILES }, (fs) => {
			let logs = [];
			let mods = { a: module_named('a'), b: module_named('b'), odd: { meta: 1 } };
			let loaded = loader.load(fs, DIR, (id) => mods[id] ?? die(`Unable to compile module\nmore`), (level, m) => push(logs, [ level, m ]), null,
				(ids) => die(`Unable to compile module\nmore`));

			assert.match([ 'a', 'b' ], map(loaded, (c) => c.meta.name));
			assert.match([
				[ 'notice', 'cannot load the collectors as one program, so each is loaded alone: Unable to compile module' ],
				[ 'err', "cannot load collector 'broken': Unable to compile module" ],
				[ 'err', 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ],
			], logs);
		});
	});

	it('reports a module\'s meta by its fingerprint, as load() takes it, or why it is not valid', () => {
		let res = loader.validate('loadavg', loader.import_module('loadavg'));

		mock.inject('fs', { strict: true, data: { ...FILES, [DIR + '/loadavg.uc']: STRICT, [DIR + '/c.uc']: "'use strict' + 1;\n" } }, (fs) => {
			let imported = [];
			let import_fn = function(id) {
				push(imported, id);
				return (id == 'loadavg') ? loader.import_module(id) : { meta: 1 };
			};

			assert.match([
				{ meta: collection.fingerprint(res.data.meta), own: true },
				{ invalid: 'COLLECTOR_INVALID (odd: exports no meta)' },
				{ invalid: "COLLECTOR_INVALID (c: not in strict mode: its first statement must be 'use strict')" },
			], map([ 'loadavg', 'odd', 'c' ], (id) => loader.check_module(fs, DIR, id, import_fn)));
			assert.match([ 'loadavg', 'odd' ], imported, 'what its text refuses, it never loads');
		});
	});

	it('imports a collector module by its name', () => {
		assert.match('loadavg', loader.import_module('loadavg').meta.name);
		assert.throws(() => loader.import_module('does_not_exist'), regex(/Unable to/));
	});

	it('imports collector modules as one program, by their names', () => {
		let mods = loader.import_modules([ 'loadavg', 'uname' ]);

		assert.match([ 'loadavg', 'uname' ], [ mods.loadavg.meta.name, mods.uname.meta.name ]);
		assert.match({}, loader.import_modules([]));
		assert.throws(() => loader.import_modules([ 'loadavg', 'does_not_exist' ]), regex(/Unable to/));
	});
});
