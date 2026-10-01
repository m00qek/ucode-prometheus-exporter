'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as Result from 'prometheus_exporter.result';

describe('result', () => {
	it('ok carries its data, null for none', () => {
		assert.match({ ok: true, data: { k: 'v' } }, { ...Result.ok({ k: 'v' }) });
		assert.match(null, Result.ok().data);
	});

	it('err carries its code, details and data for the caller', () => {
		assert.match({ ok: false, error: 'SOURCE_INVALID', details: { line: 3 }, data: null }, { ...Result.err('SOURCE_INVALID', { line: 3 }) });
		assert.match({ status: 94 }, Result.err('COMMAND_FAILED', 'x', { status: 94 }).data);
	});

	it('is() tells a Result from a lookalike', () => {
		assert.match([ true, true, false, false ],
			[ Result.is(Result.ok()), Result.is(Result.err('X')), Result.is({ ok: true }), Result.is(null) ]);
	});

	it('is() knows a Result made by another copy of the module, as a collector\'s is', () => {
		let other = loadstring("import * as R from 'prometheus_exporter.result'; return R;", { raw_mode: true })();

		assert.match([ false, true, true ], [ other === Result, Result.is(other.ok()), Result.is(other.err('X')) ]);
	});

	it('describe() shows string details only', () => {
		assert.match([ 'X (why)', 'X', 'X' ], [
			Result.describe(Result.err('X', 'why')),
			Result.describe(Result.err('X', { why: 1 })),
			Result.describe(Result.err('X', '')),
		]);
	});

	prop('keeps any payload', gen.tuple(gen.int(-100, 100), gen.ascii({ max_len: 20 })), (p) => {
		assert.match(p, Result.ok(p).data);
	});
});
