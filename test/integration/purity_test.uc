'use strict';

// The purity rule for real: collector modules whose top level does more than
// declare, written to a directory, checked in the probe's child processes as
// the handler checks them (app.load_probed, loader.check_module), then loaded
// in this process, which stands for uhttpd's. Each is left out, logged, and
// nothing it would have done is done, here or in its child.

import { describe, it, afterEach, assert } from 'utest';
import * as fs from 'fs';
import * as probe from 'prometheus_exporter.probe';
import * as loader from 'prometheus_exporter.loader';
import * as collection from 'prometheus_exporter.collection';
import { load_probed } from 'prometheus_exporter.app';
import { seconds } from 'prometheus_exporter.deadline';

const ONLY_DECLARES = "a collector's top level only declares, and leaves what it does to collect()";

// A collector module of name `id` whose top level runs `top`. Each that
// would leave a mark leaves it in `dir`.
function module_text(id, top) {
	return "'use strict';\n" +
		"import { Result } from 'prometheus_exporter.api';\n" +
		`export const meta = { name: '${id}', title: 'Impure on purpose', help: 'A top level that does more than declare.', needs: [] };\n` +
		`${top}\n` +
		'export function collect(deps, out) { return Result.ok(); };\n';
}

// What the loader's text check refuses (system, require) is reached here
// past it, by a name it does not read, as a module that means no harm but
// was written carelessly could: the guard of the load refuses it then.
function tops(dir) {
	return {
		pure: "const NAMES = map([ 'a', 'b' ], (n) => uc(n));",
		looper: 'while (true) ;',
		sleeper: 'sleep(100000);',
		quitter: 'exit(0);',
		dier: "die('cannot start');",
		talker: "print('hello from the top level\\n');",
		runner: `global['sys' + 'tem']('touch ${dir}/ran');`,
		piper: `global['req' + 'uire']('fs').popen('touch ${dir}/piped').close();`,
		reader: `const PASSWD = global['req' + 'uire']('fs').readfile('/etc/passwd'); global['req' + 'uire']('fs').writefile('${dir}/read', PASSWD);`,
		signaller: "signal('SIGTERM', 'SIG_IGN');",
		formatter: "import { exposition } from 'prometheus_exporter.api';\nconst NAME = exposition.sanitize('a-b');",
	};
}

function now() {
	return seconds(clock(true));
}

let dir = null;

describe('the top level of a collector module', () => {
	afterEach(() => {
		for (let f in fs.lsdir(dir) ?? [])
			fs.unlink(`${dir}/${f}`);
		fs.rmdir(dir);
		gc();
	});

	it('is refused by the probe when it does more than declare, and this process is never affected', () => {
		dir = fs.mkdtemp('/tmp/purity-XXXXXX');

		let ids = sort(keys(tops(dir)));

		for (let id, top in tops(dir))
			fs.writefile(`${dir}/${id}.uc`, module_text(id, top));

		let saved = {};
		for (let name in keys(collection.TRAPPED))
			saved[name] = global[name];

		let import_one = (id) => collection.import_path(`${dir}/${id}.uc`);
		let check = (id) => loader.check_module(fs, dir, id, import_one);
		let logs = [];
		let t = now();
		let res = load_probed(ids, (pending) => probe.probe(pending, check, 1, null, true), (level, msg) => push(logs, [ level, msg ]), {
			all: (several) => { let out = {}; for (let id in several) out[id] = import_one(id); return out; },
			one: import_one,
		});
		let took = now() - t;

		assert.match([ 'pure' ], map(res.collectors, (c) => c.id));

		let impure = (id, name, does) => [ 'err', `skipping collector: COLLECTOR_IMPURE (${id}: its top level called ${name}(), which ${does}: ${ONLY_DECLARES})` ];

		assert.match([
			[ 'err', "cannot load collector 'dier': cannot start" ],
			impure('formatter', 'loadstring', collection.TRAPPED.loadstring),
			[ 'err', "collector 'looper' hung at load: still loading after 1 s: stopped; it is left out" ],
			impure('piper', 'require', collection.TRAPPED.require),
			impure('quitter', 'exit', collection.TRAPPED.exit),
			impure('reader', 'require', collection.TRAPPED.require),
			impure('runner', 'system', collection.TRAPPED.system),
			impure('signaller', 'signal', collection.TRAPPED.signal),
			impure('sleeper', 'sleep', collection.TRAPPED.sleep),
			impure('talker', 'print', collection.TRAPPED.print),
		], logs);

		// Refused before it ran: the hung one took its second, the sleeper none.
		assert.match(true, took < 4, `took ${took} s`);
		assert.match([ null, null, null ], [ fs.stat(`${dir}/ran`), fs.stat(`${dir}/piped`), fs.stat(`${dir}/read`) ]);

		for (let name, fn in saved)
			assert.match(true, global[name] === fn, name);
	});

	// A module whose top level does what it did not in the probe's child:
	// the second load, uhttpd's, refuses it as the child would have, and
	// leaves it out, rather than the call blocking or ending the process.
	it('is refused at the second load too, in the process that serves the scrapes', () => {
		dir = fs.mkdtemp('/tmp/purity-XXXXXX');

		let meta = { name: 'late', title: 'Impure on purpose', help: 'A top level that does more than declare.', needs: [] };

		fs.writefile(`${dir}/late.uc`, module_text('late', 'sleep(100000);'));

		let logs = [];
		let t = now();
		let res = load_probed([ 'late' ],
			(ids) => ({ late: { ok: true, error: null, hung: false, seconds: 0, data: { meta: collection.fingerprint({ options: {}, ...meta }), own: false } } }),
			(level, msg) => push(logs, [ level, msg ]),
			{ all: (ids) => ({ late: collection.import_path(`${dir}/late.uc`) }), one: (id) => collection.import_path(`${dir}/${id}.uc`) });
		let why = `its top level called sleep(), which ${collection.TRAPPED.sleep}: ${ONLY_DECLARES}`;

		assert.match([], res.collectors);
		assert.match([
			[ 'notice', `cannot load the collectors as one program, so each is loaded alone: COLLECTOR_IMPURE (${why})` ],
			[ 'err', `skipping collector: COLLECTOR_IMPURE (late: ${why})` ],
		], logs);
		assert.match(true, now() - t < 2);
	});
});

describe('the collectors the packages ship', () => {
	afterEach(() => gc());

	it('load under the guard, each alone and all as one program', () => {
		let ids = loader.discover(fs, 'src/prometheus_exporter/collectors');
		let res = probe.probe(ids, collection.import_module);

		assert.match([], filter(ids, (id) => !res[id]?.ok));
		assert.match(length(ids), length(keys(collection.import_modules(ids))));
	});
});
