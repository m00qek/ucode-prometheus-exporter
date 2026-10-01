'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as config from 'prometheus_exporter.config';

function with_uci(sections, cb) {
	mock.inject('uci', { strict: true, data: { [config.NAME]: sections } }, (uci) => cb(uci.cursor()));
}

// Options declared with these defaults.
function specs(defaults) {
	let out = {};
	for (let k, v in defaults)
		out[k] = { default: v, help: 'H.' };
	return out;
}

// The meta of a collector with options of these defaults, and these needs.
function meta(defaults, needs, extra) {
	return { needs: needs ?? [], options: specs(defaults), ...(extra ?? {}) };
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
				config.collector(uci, 'wifi', meta({ stations: true, directory: '/var/prometheus' })).data);
		});
	});

	it('gives the defaults for a missing section, or one of another type', () => {
		with_uci({ wifi: { '.type': 'interface', stations: '0' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', meta({ stations: true })).data);
			assert.match({ stations: true }, config.collector(uci, 'other', meta({ stations: true })).data);
		});
	});

	it('ignores options nobody declared', () => {
		with_uci({ wifi: { '.type': 'collector', stations: '1', removed_long_ago: 'x' } }, (uci) => {
			assert.match({ stations: true }, config.collector(uci, 'wifi', meta({ stations: false })).data);
		});
	});

	it('fails on the first invalid option', () => {
		with_uci({ wifi: { '.type': 'collector', stations: 'maybe' } }, (uci) => {
			assert.match('CONFIG_INVALID: stations: expected a boolean, got "maybe"',
				err_details(config.collector(uci, 'wifi', meta({ stations: true }))));
		});
	});

	it('checks enabled, and leaves it out of the options', () => {
		with_uci({
			wifi: { '.type': 'collector', enabled: '0', stations: '0' },
			cpu: { '.type': 'collector', enabled: 'maybe' },
		}, (uci) => {
			assert.match({ stations: false }, config.collector(uci, 'wifi', meta({ stations: true })).data);
			assert.match({}, config.collector(uci, 'time', meta({})).data);
			assert.match('CONFIG_INVALID: enabled: expected a boolean, got "maybe"', err_details(config.collector(uci, 'cpu', meta({}))));
		});
	});
});

describe('config.settings', () => {
	const EXEC = meta({ stations: true }, [ 'exec' ]);
	const OWN = meta({}, [ 'exec' ], { timeout: 12 });

	// The seconds of a collector with this meta, for a main section's exec_timeout
	// and its section's timeout (null for none).
	function seconds(m, exec_timeout, timeout) {
		let out;
		let sections = {};

		if (exec_timeout != null)
			sections.main = { '.type': config.NAME, exec_timeout };
		if (timeout != null)
			sections.c = { '.type': 'collector', timeout };

		with_uci(sections, (uci) => {
			let res = config.settings(uci, 'c', m);
			out = res.ok ? [ res.data.timeout, config.timeout_source(uci, 'c', m) ] : `${res.error}: ${res.details}`;
		});

		return out;
	}

	it('gives enabled, the timeout and the options apart', () => {
		with_uci({ c: { '.type': 'collector', enabled: '0', stations: '0', timeout: '7' } }, (uci) => {
			assert.match({ enabled: false, timeout: 7, options: { stations: false } }, config.settings(uci, 'c', EXEC).data);
			assert.match({ stations: false }, config.collector(uci, 'c', EXEC).data);
		});
	});

	it('takes the section\'s timeout, then meta.timeout, then the main section\'s exec_timeout', () => {
		assert.match([
			[ config.EXEC_TIMEOUT, 'exec_timeout' ],
			[ 8, 'exec_timeout' ],
			[ 12, 'meta.timeout' ],
			[ 3, 'timeout' ],
			[ 3, 'timeout' ],
		], [
			seconds(EXEC, null, null),
			seconds(EXEC, '8', null),
			seconds(OWN, '8', null),
			seconds(EXEC, '8', '3'),
			seconds(OWN, '8', '3'),
		]);
	});

	it('has no timeout for a collector that runs no programs, which ignores one in its section', () => {
		assert.match([ null, null ], seconds(meta({}, [ 'fs' ]), '8', 'not seconds'));
		assert.match(null, seconds(meta({}, [ 'fs' ]), '8', '3')[1]);
	});

	it('fails the collector on a timeout that is not 1 to 30 seconds', () => {
		assert.match([
			'CONFIG_INVALID: timeout: expected an integer from 1 to 30, got 0',
			'CONFIG_INVALID: timeout: expected an integer from 1 to 30, got 31',
			'CONFIG_INVALID: timeout: expected an integer, got "soon"',
		], [ seconds(EXEC, null, '0'), seconds(OWN, null, '31'), seconds(EXEC, null, 'soon') ]);
	});

	it('falls back to the default exec_timeout while the main section is not valid', () => {
		assert.match([ config.EXEC_TIMEOUT, 'exec_timeout' ], seconds(EXEC, '0', null));
	});

	prop('the section\'s timeout wins whenever it is valid', gen.tuple(gen.int(-5, 35), gen.int(1, 30), gen.bool()), (t) => {
		let n = t[0], exec_timeout = t[1], own = t[2];
		let got = seconds(own ? OWN : EXEC, '' + exec_timeout, '' + n);

		if (n >= 1 && n <= config.EXEC_TIMEOUT_MAX)
			assert.match([ n, 'timeout' ], got);
		else
			assert.match(`CONFIG_INVALID: timeout: expected an integer from 1 to 30, got ${n}`, got);
	});

	prop('without one, meta.timeout wins over exec_timeout', gen.tuple(gen.int(1, 30), gen.bool()), (t) => {
		let exec_timeout = t[0], own = t[1];

		assert.match(own ? [ 12, 'meta.timeout' ] : [ exec_timeout, 'exec_timeout' ], seconds(own ? OWN : EXEC, '' + exec_timeout, null));
	});
});

describe('config.core', () => {
	it('gives every collector enabled, and one that runs programs timeout too', () => {
		assert.match([ 'enabled' ], keys(config.core(meta({}, [ 'fs', 'ubus' ]), 5)));
		assert.match({ enabled: config.ENABLED, timeout: { default: 9, ...config.TIMEOUT } }, config.core(meta({}, [ 'exec' ]), 9));
	});

	it('reserves the names of its options', () => {
		assert.match(config.RESERVED, keys(config.core(meta({}, [ 'exec' ]), 5)));
		assert.match('range(1,30)', config.TIMEOUT.datatype);
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
		with_uci({ main: { '.type': config.NAME, omit_zero_values: '1', listen_port: '9100' } }, (uci) => {
			assert.match({ omit_zero_values: true, exec_timeout: config.EXEC_TIMEOUT }, config.main(uci).data);
		});
	});

	it('reads exec_timeout, 1 to 30 seconds, and refuses any other', () => {
		let main = (v) => {
			let out;
			with_uci({ main: { '.type': config.NAME, exec_timeout: v } }, (uci) => { out = config.main(uci); });
			return out.ok ? out.data.exec_timeout : `${out.error}: ${out.details}`;
		};

		assert.match([
			1, 30,
			'CONFIG_INVALID: exec_timeout: expected an integer from 1 to 30, got 0',
			'CONFIG_INVALID: exec_timeout: expected an integer from 1 to 30, got 31',
			'CONFIG_INVALID: exec_timeout: expected an integer, got "5s"',
		], map([ '1', '30', '0', '31', '5s' ], main));
	});

	prop('takes exec_timeout from 1 to 30 and no other integer', gen.int(-100, 100), (n) => {
		with_uci({ main: { '.type': config.NAME, exec_timeout: '' + n } }, (uci) => {
			let res = config.main(uci);
			assert.match(n >= 1 && n <= config.EXEC_TIMEOUT_MAX, res.ok);
			assert.match(res.ok ? n : 'CONFIG_INVALID', res.ok ? res.data.exec_timeout : res.error);
		});
	});
});

describe('config.service', () => {
	function service(main) {
		let out;
		with_uci(main ? { main: { '.type': config.NAME, ...main } } : {}, (uci) => { out = config.service(uci); });
		return out.ok ? out.data : err_details(out);
	}

	it('gives the init script\'s defaults for a missing section', () => {
		assert.match(config.defaults(config.SERVICE_OPTIONS), service(null));
		assert.match({ enabled: true, listen_interface: 'loopback', listen_port: 9100, http_keepalive: 70, cert: '', key: '' }, service(null));
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
