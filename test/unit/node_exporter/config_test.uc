'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as config from 'node_exporter.config';

function with_uci(sections, cb) {
	mock.inject('uci', { strict: true, data: { [config.PACKAGE]: sections } }, (uci) => cb(uci.cursor()));
}

// Options declared with these defaults.
function specs(defaults) {
	let out = {};
	for (let k, v in defaults)
		out[k] = { default: v, help: 'H.' };
	return out;
}

function spec(fallback, datatype) {
	return { default: fallback, help: 'H.', datatype };
}

function err_details(res) {
	return res.ok ? null : `${res.error}: ${res.details}`;
}

describe('config.convert', () => {
	it('takes uci booleans for a boolean default', () => {
		for (let v in [ '1', 'yes', 'on', 'true', 'enabled' ])
			assert.match(true, config.convert('o', v, spec(false)).data);
		for (let v in [ '0', 'no', 'off', 'false', 'disabled' ])
			assert.match(false, config.convert('o', v, spec(true)).data);
	});

	it('says what it expected and what it got', () => {
		assert.match([
			'CONFIG_INVALID: o: expected a boolean, got "maybe"',
			'CONFIG_INVALID: o: expected an integer, got "1.5"',
			'CONFIG_INVALID: o: expected a single value, got [ "a", "b" ]',
			'CONFIG_INVALID: o: expected a boolean, got [ "1" ]',
		], [
			err_details(config.convert('o', 'maybe', spec(true))),
			err_details(config.convert('o', '1.5', spec(7))),
			err_details(config.convert('o', [ 'a', 'b' ], spec(''))),
			err_details(config.convert('o', [ '1' ], spec(true))),
		]);
	});

	prop('reads back any integer', gen.int(-2147483648, 2147483647), (n) => {
		assert.match(n, config.convert('o', '' + n, spec(0)).data);
	});

	prop('refuses any other word for a boolean',
		gen.filter(gen.alphanumeric({ min_len: 0, max_len: 8 }),
			(s) => !(s in [ '1', 'yes', 'on', 'true', 'enabled', '0', 'no', 'off', 'false', 'disabled' ])), (s) => {
			assert.match('CONFIG_INVALID', config.convert('o', s, spec(true)).error);
		});
});

describe('config.collector', () => {
	it('fills unset options with their defaults, typed', () => {
		with_uci({ wifi: { '.type': 'collector', stations: '0' } }, (uci) => {
			assert.match({ stations: false, directory: '/var/prometheus' },
				config.collector(uci, 'wifi', specs({ stations: true, directory: '/var/prometheus' })).data);
		});
	});

	it('gives the defaults for a missing section, or one of another type', () => {
		with_uci({ wifi: { '.type': 'interface', stations: '0' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', specs({ stations: true })).data);
			assert.match({ stations: true }, config.collector(uci, 'other', specs({ stations: true })).data);
		});
	});

	it('ignores options nobody declared', () => {
		with_uci({ wifi: { '.type': 'collector', stations: '1', removed_long_ago: 'x' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', specs({ stations: false })).data);
		});
	});

	it('fails on the first invalid option', () => {
		with_uci({ wifi: { '.type': 'collector', stations: 'maybe' } }, (uci) => {
			assert.match('CONFIG_INVALID: stations: expected a boolean, got "maybe"',
				err_details(config.collector(uci, 'wifi', specs({ stations: true }))));
		});
	});

	it('checks enabled, and leaves it out of the options', () => {
		with_uci({
			wifi: { '.type': 'collector', enabled: '0', stations: '0' },
			cpu: { '.type': 'collector', enabled: 'maybe' },
		}, (uci) => {
			assert.match({ stations: false }, config.collector(uci, 'wifi', specs({ stations: true })).data);
			assert.match({}, config.collector(uci, 'time', specs({})).data);
			assert.match('CONFIG_INVALID: enabled: expected a boolean, got "maybe"', err_details(config.collector(uci, 'cpu', specs({}))));
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

describe('config.service', () => {
	function service(main) {
		let out;
		with_uci(main ? { main: { '.type': config.PACKAGE, ...main } } : {}, (uci) => { out = config.service(uci); });
		return out.ok ? out.data : err_details(out);
	}

	it('gives the init script\'s defaults for a missing section', () => {
		assert.match(config.defaults(config.SERVICE_OPTIONS), service(null));
		assert.match({ enabled: true, listen_interface: 'loopback', listen_port: 9101, http_keepalive: 70, cert: '', key: '' }, service(null));
	});

	it('reads the options, typed', () => {
		assert.match({ enabled: false, listen_interface: '*', listen_port: 9100, http_keepalive: 0, cert: '/etc/x.crt', key: '' },
			service({ enabled: '0', listen_interface: '*', listen_port: '9100', http_keepalive: '0', cert: '/etc/x.crt' }));
	});

	it('refuses what the init script would misread', () => {
		assert.match([
			'CONFIG_INVALID: listen_port: expected an integer, got "http"',
			'CONFIG_INVALID: listen_port: expected an integer from 1 to 65535, got 0',
			'CONFIG_INVALID: http_keepalive: expected an integer of 0 or more, got -1',
			'CONFIG_INVALID: listen_interface: expected an interface name or *, got ""',
			'CONFIG_INVALID: enabled: expected a boolean, got "maybe"',
		], [
			service({ listen_port: 'http' }),
			service({ listen_port: '0' }),
			service({ http_keepalive: '-1' }),
			service({ listen_interface: '' }),
			service({ enabled: 'maybe' }),
		]);
	});

	prop('takes any port from 1 to 65535', gen.int(1, 65535), (n) => {
		assert.match(n, service({ listen_port: '' + n }).listen_port);
	});
});

describe('config.datatype', () => {
	function check(datatype, value) {
		let res = config.convert('o', value, spec(match(value, /^-?[0-9]+$/) && datatype != 'regex' && datatype != 'file' ? 0 : '', datatype));
		return res.ok ? true : res.details;
	}

	it('knows the datatypes the collectors and the main section use, and no other', () => {
		assert.match([ true, true, true, true, true ],
			map([ 'uinteger', 'directory', 'file', 'regex', 'range(1,65535)' ], (n) => config.datatype(n) != null));
		assert.match([ null, null, null, null ], map([ 'ipaddr', 'range(9,1)', 'range(1)', 7 ], config.datatype));
	});

	it('says what a value of each should be', () => {
		assert.match([
			'o: expected an integer of 0 or more, got -1',
			'o: expected an integer from 1 to 65535, got 65536',
			'o: expected an absolute path, got "var/prom"',
			'o: expected an absolute path, got "relative.sock"',
			'o: expected a regular expression, got "(pg"',
		], [
			check('uinteger', '-1'),
			check('range(1,65535)', '65536'),
			check('directory', 'var/prom'),
			check('file', 'relative.sock'),
			check('regex', '(pg'),
		]);
	});

	it('takes a path that does not exist: the check is of its form', () => {
		assert.match([ true, true ], [ check('directory', '/no/such/dir/'), check('file', '/run/unbound.ctl') ]);
	});

	prop('uinteger takes 0 and more', gen.int(-1000, 1000), (n) => {
		assert.match(n >= 0, check('uinteger', '' + n) === true);
	});

	prop('range(a,b) takes a to b', gen.tuple(gen.int(-20, 20), gen.int(-20, 20), gen.int(-30, 30)), (t) => {
		let lo = t[0] < t[1] ? t[0] : t[1], hi = t[0] < t[1] ? t[1] : t[0], n = t[2];
		assert.match(n >= lo && n <= hi, check(`range(${lo},${hi})`, '' + n) === true);
	});

	prop('directory and file take any absolute path', gen.string({ charset: 'ab/._-', min_len: 0, max_len: 10 }), (s) => {
		assert.match([ true, true ], [ check('directory', '/' + s), check('file', '/' + s) ]);
		assert.match(substr(s, 0, 1) == '/', check('file', s) === true);
	});

	prop('regex takes what regexp() compiles', gen.string({ charset: 'ab()[]*+|^$', min_len: 0, max_len: 6 }), (s) => {
		let compiles = true;
		try { regexp(s); } catch (e) { compiles = false; }
		assert.match(compiles, check('regex', s) === true, s);
	});

	it('checks a value only once it has the type of the default', () => {
		assert.match('o: expected an integer, got "x"', config.convert('o', 'x', spec(5, 'uinteger')).details);
	});
});
