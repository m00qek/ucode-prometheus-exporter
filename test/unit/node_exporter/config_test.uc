'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as config from 'node_exporter.config';

function with_uci(sections, cb) {
	mock.inject('uci', { strict: true, data: { [config.PACKAGE]: sections } }, (uci) => cb(uci.cursor()));
}

function err_details(res) {
	return res.ok ? null : `${res.error}: ${res.details}`;
}

describe('config.convert', () => {
	it('takes uci booleans for a boolean default', () => {
		for (let v in [ '1', 'yes', 'on', 'true', 'enabled' ])
			assert.match(true, config.convert('o', v, false).data);
		for (let v in [ '0', 'no', 'off', 'false', 'disabled' ])
			assert.match(false, config.convert('o', v, true).data);
	});

	it('says what it expected and what it got', () => {
		assert.match([
			'CONFIG_INVALID: o: expected a boolean, got "maybe"',
			'CONFIG_INVALID: o: expected an integer, got "1.5"',
			'CONFIG_INVALID: o: expected a single value, got [ "a", "b" ]',
			'CONFIG_INVALID: o: expected a boolean, got [ "1" ]',
		], [
			err_details(config.convert('o', 'maybe', true)),
			err_details(config.convert('o', '1.5', 7)),
			err_details(config.convert('o', [ 'a', 'b' ], '')),
			err_details(config.convert('o', [ '1' ], true)),
		]);
	});

	prop('reads back any integer', gen.int(-2147483648, 2147483647), (n) => {
		assert.match(n, config.convert('o', '' + n, 0).data);
	});

	prop('refuses any other word for a boolean',
		gen.filter(gen.alphanumeric({ min_len: 0, max_len: 8 }),
			(s) => !(s in [ '1', 'yes', 'on', 'true', 'enabled', '0', 'no', 'off', 'false', 'disabled' ])), (s) => {
			assert.match('CONFIG_INVALID', config.convert('o', s, true).error);
		});
});

describe('config.collector', () => {
	it('fills unset options with their defaults, typed', () => {
		with_uci({ wifi: { '.type': 'collector', stations: '0' } }, (uci) => {
			assert.match({ stations: false, directory: '/var/prometheus' },
				config.collector(uci, 'wifi', { stations: true, directory: '/var/prometheus' }).data);
		});
	});

	it('gives the defaults for a missing section, or one of another type', () => {
		with_uci({ wifi: { '.type': 'interface', stations: '0' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', { stations: true }).data);
			assert.match({ stations: true }, config.collector(uci, 'other', { stations: true }).data);
		});
	});

	it('ignores options nobody declared', () => {
		with_uci({ wifi: { '.type': 'collector', stations: '1', removed_long_ago: 'x' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', { stations: false }).data);
		});
	});

	it('fails on the first invalid option', () => {
		with_uci({ wifi: { '.type': 'collector', stations: 'maybe' } }, (uci) => {
			assert.match('CONFIG_INVALID: stations: expected a boolean, got "maybe"',
				err_details(config.collector(uci, 'wifi', { stations: true })));
		});
	});
});

describe('config.main', () => {
	it('reads omit_zero_values from the main section', () => {
		with_uci({ main: { '.type': config.PACKAGE, omit_zero_values: '1', listen_port: '9101' } }, (uci) => {
			assert.match({ omit_zero_values: true }, config.main(uci).data);
		});
	});
});
