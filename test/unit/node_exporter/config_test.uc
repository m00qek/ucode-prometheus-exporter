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

	it('checks enabled, and leaves it out of the options', () => {
		with_uci({
			wifi: { '.type': 'collector', enabled: '0', stations: '0' },
			cpu: { '.type': 'collector', enabled: 'maybe' },
		}, (uci) => {
			assert.match({ stations: false }, config.collector(uci, 'wifi', { stations: true }).data);
			assert.match({}, config.collector(uci, 'time', {}).data);
			assert.match('CONFIG_INVALID: enabled: expected a boolean, got "maybe"', err_details(config.collector(uci, 'cpu', {})));
		});
	});
});

describe('config.enabled', () => {
	it('is true without a section, or in one of another type', () => {
		with_uci({ wifi: { '.type': 'interface', enabled: '0' } }, (uci) => {
			assert.match([ true, true ], [ config.enabled(uci, 'wifi'), config.enabled(uci, 'cpu') ]);
		});
	});

	it('counts a value that is not a boolean as enabled, so the collector fails saying why', () => {
		with_uci({ cpu: { '.type': 'collector', enabled: 'maybe' } }, (uci) => {
			assert.match(true, config.enabled(uci, 'cpu'));
		});
	});

	prop('follows any of uci\'s boolean spellings',
		gen.elements('1', 'yes', 'on', 'true', 'enabled', '0', 'no', 'off', 'false', 'disabled'), (v) => {
			with_uci({ cpu: { '.type': 'collector', enabled: v } }, (uci) => {
				assert.match(v in [ '1', 'yes', 'on', 'true', 'enabled' ], config.enabled(uci, 'cpu'));
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
