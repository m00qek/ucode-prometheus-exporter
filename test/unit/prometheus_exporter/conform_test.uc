'use strict';

import { describe, it, assert, contains } from 'utest';
import * as conform from 'prometheus_exporter.conform';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as Result from 'prometheus_exporter.result';
import { with_mods } from 'context';

const STRICT = "'use strict';\n";

function module_of(name, collect, meta) {
	return { meta: { name, title: 'Mine', help: 'Mine.', needs: [], ...(meta ?? {}) }, collect };
}

function gauge(name, value) {
	return (d, out) => { out.gauge(name)(null, value); return Result.ok(); };
}

// An installed collector.
const LOAD = loader.validate('load', module_of('load', gauge('node_load1', 1))).data;

// conform.run on a module at /tmp/<id>.uc: `files` the text of each path,
// `mods` the exports each import gives, `probed` what the load timer saw.
function check(path, opts) {
	let out;

	with_mods({}, (mods) => {
		let t = 0;

		out = conform.run({
			fs: {
				readfile: (p) => opts?.files?.[p] ?? STRICT,
				realpath: (p) => (opts?.missing ? null : p),
			},
			uci: mods.uci.cursor(),
			env: { session: () => deps.session(mods), clock: () => { t += 1000000; return [ 0, t ]; }, log: () => null },
			import_path: (p) => opts?.module,
			probe: (id, fn) => opts?.probed ?? { ok: true, hung: false, error: null, seconds: 0.002 },
			installed: [ LOAD ],
			load_timeout: 5,
		}, path);
	});

	return { ok: out.ok, lines: split(out.report, '\n') };
}

describe('conform.run', () => {
	it('passes a collector that keeps the contract, and says what it wrote', () => {
		let r = check('/tmp/mine.uc', { module: module_of('mine', function(d, out) {
			out.gauge('mine_value', 'A value.')({ i: '1' }, 1)({ i: '2' }, 2);
			return Result.ok();
		}) });

		assert.match(true, r.ok, join('\n', r.lines));
		assert.match([
			"ok   strict mode: 'use strict' first",
			'ok   load: 0.002 s, of at most 5 s',
			'ok   meta: mine (Mine), needs nothing, budget 5 s, max_samples 20000',
			'ok   run: 0.001 s, 2 samples in 1 family',
			'ok   families: mine_value',
			'ok   exposition: valid text, each series once',
		], r.lines);
	});

	it('fails one that is not in strict mode, without loading it', () => {
		let r = check('/tmp/mine.uc', { files: { '/tmp/mine.uc': 'export const meta = {};\n' } });

		assert.match([ false, [ "FAIL strict mode: its first statement must be 'use strict'" ] ], [ r.ok, r.lines ]);
	});

	it('fails one that does not load in time, or at all', () => {
		let hung = check('/tmp/mine.uc', { probed: { ok: false, hung: true, error: 'still loading after 5 s: stopped' } });
		let broken = check('/tmp/mine.uc', { probed: { ok: false, hung: false, error: 'Syntax error: unexpected token' } });

		assert.match([ false, 'FAIL load: still loading after 5 s: stopped: its top level must only declare, in at most 5 s' ], [ hung.ok, hung.lines[-1] ]);
		assert.match([ false, 'FAIL load: Syntax error: unexpected token' ], [ broken.ok, broken.lines[-1] ]);
	});

	it('fails a meta that is not valid, and a file that is not a module', () => {
		assert.match('FAIL meta: COLLECTOR_INVALID (mine: meta.help must be a sentence)',
			check('/tmp/mine.uc', { module: module_of('mine', gauge('x', 1), { help: '' }) }).lines[-1]);
		assert.match([ false, 'FAIL /tmp/README: a collector is a file <module>.uc, its module named of a-z, 0-9 and _' ],
			[ check('/tmp/README').ok, check('/tmp/README').lines[0] ]);
		assert.match('FAIL /tmp/gone.uc: cannot be read', check('/tmp/gone.uc', { missing: true }).lines[0]);
	});

	it('fails a family an installed collector writes, or one the exporter keeps', () => {
		let thief = check('/tmp/thief.uc', { module: module_of('thief', gauge('node_load1', 2)) });
		let mimic = check('/tmp/mimic.uc', { module: module_of('mimic', gauge('node_scrape_collector_success', 2)) });

		assert.match([ false, 'FAIL family node_load1: written by the installed load too; the first of the reply keeps it' ], [ thief.ok, thief.lines[-1] ]);
		assert.match([ false, true ], [ mimic.ok, index(mimic.lines[-1], 'FAIL run: ') == 0 && index(mimic.lines[-1], 'FAMILY_CONFLICT (node_scrape_collector_success belongs to the scrape itself)') > 0 ]);
	});

	it('fails one over its samples, one that crashes, and one that returns no Result', () => {
		for (let t in [
			[ module_of('big', function(d, out) { let g = out.gauge('b'); for (let i = 0; i < 20; i++) g({ i }, i); return Result.ok(); }, { max_samples: 10 }), 'SAMPLE_LIMIT' ],
			[ module_of('boom', () => die('kaput')), 'COLLECTOR_CRASHED' ],
			[ module_of('sloppy', () => 1), 'COLLECTOR_NO_RESULT' ],
		]) {
			let r = check(`/tmp/${t[0].meta.name}.uc`, { module: t[0] });

			assert.match([ false, true ], [ r.ok, index(join('\n', r.lines), `FAIL run: `) >= 0 && index(join('\n', r.lines), t[1]) > 0 ], t[1]);
		}
	});

	it('only warns of one that fails on this device, or has nothing to observe here', () => {
		let missing = check('/tmp/disk.uc', { module: module_of('disk', () => Result.err('SOURCE_UNREADABLE', '/proc/diskstats')) });
		let idle = check('/tmp/radio.uc', { module: module_of('radio', () => Result.none('no wireless radios')) });

		assert.match([ true, 'warn run: 0.001 s, 0 samples in 0 families: SOURCE_UNREADABLE (/proc/diskstats) (on this device: it may do its job on another)' ],
			[ missing.ok, missing.lines[-1] ]);
		assert.match([ true, 'warn run: 0.001 s, 0 samples in 0 families: nothing to observe on this device: no wireless radios' ], [ idle.ok, idle.lines[-1] ]);
	});

	it('names a module by its file', () => {
		assert.match([ 'ltq_dsl', 'a', null, null ], map([ '/x/ltq_dsl.uc', 'a.uc', '/x/a.txt', null ], conform.id_of_path));
	});
});
