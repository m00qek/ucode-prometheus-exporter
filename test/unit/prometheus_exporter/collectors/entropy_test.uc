'use strict';

import { describe, it, assert } from 'utest';
import { with_collector } from 'prometheus_exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as entropy from 'prometheus_exporter.collectors.entropy';

const AVAIL = '/proc/sys/kernel/random/entropy_avail';
const POOL = '/proc/sys/kernel/random/poolsize';

const ROUTER = fixtures.files('caju-router', [ AVAIL, POOL ]);
const AP = fixtures.files('caju-ap', [ AVAIL, POOL ]);

function files(avail, pool) {
	return { fs: { data: { [AVAIL]: avail, [POOL]: pool } } };
}

describe('collectors.entropy', () => {
	// Since Linux 5.18 both are 256, always.
	it('exports the available bits and the pool size of the caju router', () => {
		with_collector(entropy, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_entropy_available_bits Bits of available entropy.',
				'# TYPE node_entropy_available_bits gauge',
				'node_entropy_available_bits 256',
				'# HELP node_entropy_pool_size_bits Bits of entropy pool.',
				'# TYPE node_entropy_pool_size_bits gauge',
				'node_entropy_pool_size_bits 256',
			], r.lines);
		});
	});

	it('reads the caju AP too', () => {
		with_collector(entropy, { fs: { data: AP } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(6, length(r.lines));
		});
	});

	it('fails with SOURCE_UNREADABLE when entropy_avail cannot be read', () => {
		with_collector(entropy, files(null, '256\n'), (r) => {
			assert.match({ ok: false, error: 'SOURCE_UNREADABLE', details: AVAIL },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
			assert.match([ `collector 'entropy': SOURCE_UNREADABLE (${AVAIL})` ], r.logs);
		});
	});

	it('keeps the available bits when only the pool size cannot be read', () => {
		with_collector(entropy, files('3172\n', null), (r) => {
			assert.match({ error: 'SOURCE_UNREADABLE', details: POOL }, { error: r.result.error, details: r.result.details });
			assert.match('node_entropy_available_bits 3172', r.lines[-1]);
		});
	});

	it('fails with SOURCE_INVALID for a value that is not a count', () => {
		with_collector(entropy, files('256\n', 'four thousand\n'), (r) => {
			assert.match({ error: 'SOURCE_INVALID', details: `${POOL}: "four thousand"` },
				{ error: r.result.error, details: r.result.details });
		});
	});
});
