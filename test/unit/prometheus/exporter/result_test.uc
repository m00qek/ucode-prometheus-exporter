'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as Result from 'prometheus.exporter.result';

describe('result', () => {
	it('ok carries its data, null for none', () => {
		assert.match({ ok: true, data: { k: 'v' } }, { ...Result.ok({ k: 'v' }) });
		assert.match(null, Result.ok().data);
	});

	it('err carries its code, details and data for the caller', () => {
		assert.match({ ok: false, error: 'SOURCE_INVALID', details: { line: 3 }, data: null }, { ...Result.err('SOURCE_INVALID', { line: 3 }) });
		assert.match({ status: 94 }, Result.err('COMMAND_FAILED', 'x', { status: 94 }).data);
	});

	it('none is ok with nothing to observe, and says why', () => {
		let r = Result.none('no wireless radios');

		assert.match({ ok: true, data: null, none: 'no wireless radios' }, { ...r });
		assert.match([ true, true ], [ Result.is(r), Result.is_none(r) ]);
	});

	it('is_none() tells nothing to observe from any other Result', () => {
		assert.match([ false, false, false, false, true ], [
			Result.is_none(Result.ok()),
			Result.is_none(Result.ok('no wireless radios')),
			Result.is_none(Result.err('X', 'why')),
			Result.is_none(null),
			Result.is_none(Result.none()),
		]);
	});

	it('is_none() knows a none made by another copy of the module, as a collector\'s is', () => {
		let other = loadstring("import * as R from 'prometheus.exporter.result'; return R;", { raw_mode: true })();

		assert.match([ true, 'dnsmasq is disabled' ], [ Result.is_none(other.none('dnsmasq is disabled')), other.none('dnsmasq is disabled').none ]);
	});

	it('is() tells a Result from a lookalike', () => {
		assert.match([ true, true, false, false ],
			[ Result.is(Result.ok()), Result.is(Result.err('X')), Result.is({ ok: true }), Result.is(null) ]);
	});

	it('is() knows a Result made by another copy of the module, as a collector\'s is', () => {
		let other = loadstring("import * as R from 'prometheus.exporter.result'; return R;", { raw_mode: true })();

		assert.match([ false, true, true ], [ other === Result, Result.is(other.ok()), Result.is(other.err('X')) ]);
	});

	it('describe() shows string details only', () => {
		assert.match([ 'X (why)', 'X', 'X' ], [
			Result.describe(Result.err('X', 'why')),
			Result.describe(Result.err('X', { why: 1 })),
			Result.describe(Result.err('X', '')),
		]);
	});

	prop('none keeps any reason, as a string', gen.ascii({ min_len: 1, max_len: 30 }), (why) => {
		let r = Result.none(why);
		assert.match([ true, true, why ], [ r.ok, Result.is_none(r), r.none ]);
	});

	prop('keeps any payload', gen.tuple(gen.int(-100, 100), gen.ascii({ max_len: 20 })), (p) => {
		assert.match(p, Result.ok(p).data);
	});
});
