'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as deadline from 'prometheus.exporter.deadline';
import * as config from 'prometheus.exporter.config';

// The real fs: under utest, an import of fs reaches whatever mock is patched in.
const fs = require('fs');
const INIT = `${fs.dirname(sourcepath())}/../../../files/etc/init.d/prometheus-exporter`;

describe('deadline.timeout', () => {
	it('is the scraper\'s, as Prometheus sends it', () => {
		assert.match([ 10, 9.5, 0.25, 15 ], map([ '10', '9.5', '.25', ' 15 ' ], (v) => deadline.timeout(v, 30)));
	});

	it('is scrape_timeout without a header, or with one that is not a positive number', () => {
		assert.match([ 7, 7, 7, 7, 7, 7 ], map([ null, '', '0', '-3', 'ten', '1e3' ], (v) => deadline.timeout(v, 7)));
	});

	it('is never more than uhttpd gives the handler', () => {
		assert.match([ config.SCRIPT_TIMEOUT, config.SCRIPT_TIMEOUT ], [ deadline.timeout('300', 10), deadline.timeout(null, 90) ]);
	});

	it('is uhttpd\'s -t, as the init script sets it', () => {
		assert.match(true, index(fs.readfile(INIT), `procd_append_param command -t ${config.SCRIPT_TIMEOUT}\n`) >= 0);
	});
});

describe('deadline.budget', () => {
	it('keeps back the margin', () => {
		assert.match([ 9.5, 29.5, 1.5 ], map([ 10, 30, 2 ], deadline.budget));
	});

	it('never keeps back more than half', () => {
		assert.match([ 0.5, 0.25 ], map([ 1, 0.5 ], deadline.budget));
	});

	prop('is less than the timeout, and at least half of it', gen.int(1, 60000), (ms) => {
		let t = ms / 1000.0;
		let b = deadline.budget(t);

		assert.match([ true, true, true ], [ b < t, b >= t / 2, t - b <= deadline.MARGIN + 1e-9 ]);
	});
});

describe('deadline.seconds', () => {
	it('reads a monotonic clock as seconds', () => {
		assert.match(12.25, deadline.seconds([ 12, 250000000 ]));
	});
});
