'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as collection from 'prometheus.exporter.collection';

// What top_level() throws, or null when the program returns.
function refusal(program) {
	try {
		collection.top_level(program);
	} catch (e) {
		return e.message;
	}

	return null;
}

const ONLY_DECLARES = "a collector's top level only declares, and leaves what it does to collect()";

describe('collection.top_level', () => {
	it('runs a program that only declares, and gives back what it returns', () => {
		assert.match({ a: 1, re: true }, collection.top_level(() => ({ a: length([ 1 ]), re: match('x', regexp('^x$')) != null })));
	});

	it('refuses each trapped function before it runs, saying what it does', () => {
		for (let name, does in collection.TRAPPED)
			assert.match(`COLLECTOR_IMPURE (its top level called ${name}(), which ${does}: ${ONLY_DECLARES})`,
				refusal(() => global[name]('/nonexistent')), name);
	});

	it('refuses sleep at once, rather than sleeping', () => {
		let t = clock(true);

		assert.match(true, index(refusal(() => sleep(60000)), 'called sleep()') > 0);
		assert.match(true, clock(true)[0] - t[0] < 2);
	});

	it('gives each function back once the program is done, whatever it did', () => {
		let before = {};

		for (let name in keys(collection.TRAPPED))
			before[name] = global[name];

		refusal(() => sleep(1));
		refusal(() => die('its own'));
		collection.top_level(() => 1);

		for (let name, fn in before)
			assert.match(true, global[name] === fn, name);
	});

	it('refuses a module that caught the refusal, after it', () => {
		assert.match(true, index(refusal(function() {
			try {
				exit(3);
			} catch (e) {
			}
			return 1;
		}), 'called exit()') > 0);
	});

	it('refuses a call made from a function the top level runs, as map() runs one', () => {
		assert.match(true, index(refusal(() => map([ 1 ], (x) => print(x))), 'called print()') > 0);
	});

	it('throws what the program throws of its own, as it is', () => {
		assert.match('boom', refusal(() => die('boom')));
	});

	prop('refuses whichever trapped function is called first, among pure ones', gen.tuple(gen.elements(...keys(collection.TRAPPED)), gen.int(0, 5)), (t) => {
		let why = refusal(function() {
			for (let i = 0; i < t[1]; i++)
				join(',', [ i ]);
			global[t[0]]('x');
			sleep(1);
		});

		assert.match(true, index(why, `called ${t[0]}()`) > 0, why);
	});
});

describe('collection.load_error', () => {
	it('names a top level that did more than declare as COLLECTOR_IMPURE, and anything else as not loaded', () => {
		assert.match([
			'skipping collector: COLLECTOR_IMPURE (mine: its top level called sleep(), which blocks the process)',
			"cannot load collector 'mine': Syntax error: unexpected token",
			"cannot load collector 'mine': COLLECTOR_INVALID (mine: no)",
		], [
			collection.load_error('mine', 'COLLECTOR_IMPURE (its top level called sleep(), which blocks the process)'),
			collection.load_error('mine', 'Syntax error: unexpected token'),
			collection.load_error('mine', 'COLLECTOR_INVALID (mine: no)'),
		]);
	});

	it('is what the probe\'s outcome leaves a module out with', () => {
		assert.match([
			'skipping collector: COLLECTOR_IMPURE (mine: its top level called exit(), which ends the process)',
			"collector 'mine' hung at load: still loading after 5 s: stopped; it is left out",
			null,
		], [
			collection.left_out('mine', { ok: false, hung: false, error: 'COLLECTOR_IMPURE (its top level called exit(), which ends the process)' }),
			collection.left_out('mine', { ok: false, hung: true, error: 'still loading after 5 s: stopped' }),
			collection.left_out('mine', { ok: true }),
		]);
	});
});
