'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as types from 'prometheus_exporter.config.types';

function spec(fallback, datatype) {
	return { default: fallback, help: 'H.', datatype };
}

function err_details(res) {
	return res.ok ? null : `${res.error}: ${res.details}`;
}

describe('config.types.convert', () => {
	it('takes uci booleans for a boolean default', () => {
		for (let v in [ '1', 'yes', 'on', 'true', 'enabled' ])
			assert.match(true, types.convert('o', v, spec(false)).data);
		for (let v in [ '0', 'no', 'off', 'false', 'disabled' ])
			assert.match(false, types.convert('o', v, spec(true)).data);
	});

	it('says what it expected and what it got', () => {
		assert.match([
			'CONFIG_INVALID: o: expected a boolean, got "maybe"',
			'CONFIG_INVALID: o: expected an integer, got "1.5"',
			'CONFIG_INVALID: o: expected a single value, got [ "a", "b" ]',
			'CONFIG_INVALID: o: expected a boolean, got [ "1" ]',
		], [
			err_details(types.convert('o', 'maybe', spec(true))),
			err_details(types.convert('o', '1.5', spec(7))),
			err_details(types.convert('o', [ 'a', 'b' ], spec(''))),
			err_details(types.convert('o', [ '1' ], spec(true))),
		]);
	});

	prop('reads back any integer', gen.int(-2147483648, 2147483647), (n) => {
		assert.match(n, types.convert('o', '' + n, spec(0)).data);
	});

	prop('refuses any other word for a boolean',
		gen.filter(gen.alphanumeric({ min_len: 0, max_len: 8 }),
			(s) => !(s in [ '1', 'yes', 'on', 'true', 'enabled', '0', 'no', 'off', 'false', 'disabled' ])), (s) => {
			assert.match('CONFIG_INVALID', types.convert('o', s, spec(true)).error);
		});
});

describe('config.types.datatype', () => {
	function check(datatype, value) {
		let res = types.convert('o', value, spec(match(value, /^-?[0-9]+$/) && datatype != 'regex' && datatype != 'file' ? 0 : '', datatype));
		return res.ok ? true : res.details;
	}

	it('knows the datatypes the collectors and the main section use, and no other', () => {
		assert.match([ true, true, true, true, true ],
			map([ 'uinteger', 'directory', 'file', 'regex', 'range(1,65535)' ], (n) => types.datatype(n) != null));
		assert.match(true, types.datatype('owned_directory') != null);
		assert.match([ null, null, null, null ], map([ 'ipaddr', 'range(9,1)', 'range(1)', 7 ], types.datatype));
	});

	it('makes a range once, and checks by it every time', () => {
		let a = types.datatype('range(1,60)');

		assert.match(true, a === types.datatype('range(1,60)'), 'the same range');
		assert.match([ true, false, false ], [ a.check(60), a.check(61), a.check(0) ]);
		assert.match([ true, 'o: expected an integer from 1 to 60, got 61' ], [ check('range(1,60)', '60'), check('range(1,60)', '61') ]);
	});

	prop('checks a range as its bounds say, made or remembered',
		gen.tuple(gen.int(-50, 50), gen.int(0, 50), gen.int(-120, 120)), (t) => {
			let lo = t[0], hi = t[0] + t[1];

			for (let i = 0; i < 2; i++)
				assert.match(t[2] >= lo && t[2] <= hi, types.datatype(`range(${lo},${hi})`).check(t[2]));
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

	it('owned_directory takes a directory under /var, /tmp or /etc/prometheus-exporter, and no other', () => {
		assert.match([ true, true, true, true ], map([ '/var/prometheus', '/tmp/a/b/', '/etc/prometheus-exporter/m', '/var/lib/metrics' ], (d) => check('owned_directory', d)));
		assert.match('o: expected a directory under /var, /tmp or /etc/prometheus-exporter, which the service makes and mounts, got "/srv/prom"',
			check('owned_directory', '/srv/prom'));

		for (let d in [ '/var', '/tmp/', '/etc/prometheus-exporter', '/etc/config', '/var/../etc/x', '/tmp/./x', 'var/x', '/variable/x', '/', '' ])
			assert.match(false, check('owned_directory', d) === true, d);
	});

	prop('owned_directory takes what is_owned_directory takes', gen.string({ charset: 'atvmp/._', min_len: 0, max_len: 12 }), (s) => {
		assert.match(types.is_owned_directory(s), check('owned_directory', s) === true, s);
	});

	it('checks a value only once it has the type of the default', () => {
		assert.match('o: expected an integer, got "x"', types.convert('o', 'x', spec(5, 'uinteger')).details);
	});
});
