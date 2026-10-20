'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as rpc_validate from 'prometheus.exporter.rpc.validate';
import * as config from 'prometheus.exporter.config';
import * as crypt from 'prometheus.exporter.crypt';
import * as auth from 'prometheus.exporter.auth';
import { ALL, with_sys } from 'lib.rpc';

// The refusals of a reply by field, as their English alone.
function messages(errors) {
	let out = {};

	for (let name, r in errors)
		out[name] = r.message;

	return out;
}

// The refusals of a reply by field, without their English.
function codes(errors) {
	let out = {};

	for (let name, r in errors) {
		out[name] = { ...r };
		delete out[name].message;
	}

	return out;
}

// Every option name validate takes, of the main section and of the test collectors.
function validate_names() {
	return uniq([ ...rpc_validate.MAIN_OPTIONS, ...config.RESERVED, 'retries', 'verbose', 'label' ]);
}

describe('rpc_validate.validate.validate', () => {
	function validate(args, collectors) {
		let out;

		with_sys({}, { collectors: collectors ?? ALL }, (sys) => {
			out = rpc_validate.validate(sys, args);
		});

		return out;
	}

	it('passes valid values for the main section and the collectors', () => {
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate({
			main: { enabled: '1', listen_interface: '*', listen_port: '9102', http_keepalive: '0', cert: '/etc/ssl/x.crt', key: '/etc/ssl/x.key', omit_zero_values: 'yes' },
			collectors: { wifi: { enabled: '0', stations: 'off' }, sampler: { retries: '-2', label: 'y' } },
		}));
	});

	it('says what the exporter would refuse of the main section, field by field, by its code and arguments', () => {
		assert.match({ ok: false, errors: { main: {
			listen_port: { code: 'RANGE', min: 1, max: 65535, value: 0, message: 'expected an integer from 1 to 65535, got 0' },
			http_keepalive: { code: 'UINTEGER', value: -1, message: 'expected an integer of 0 or more, got -1' },
			omit_zero_values: { code: 'BOOLEAN', value: 'maybe', message: 'expected a boolean, got "maybe"' },
			enabled: { code: 'BOOLEAN', value: '2', message: 'expected a boolean, got "2"' },
		}, collectors: {} } }, validate({
			main: { listen_port: '0', http_keepalive: '-1', omit_zero_values: 'maybe', enabled: '2', listen_interface: 'lan' },
		}));
	});

	it('says what the exporter would refuse of a collector\'s options and its enabled switch', () => {
		let res = validate({
			collectors: { wifi: { enabled: 'maybe', stations: 'x' }, sampler: { retries: '1.5', label: [ 'a', 'b' ], verbose: '1' } },
		});

		assert.match([ false, {}, [ 'wifi', 'sampler' ] ], [ res.ok, res.errors.main, keys(res.errors.collectors) ]);
		assert.match([
			{ enabled: { code: 'BOOLEAN', value: 'maybe' }, stations: { code: 'BOOLEAN', value: 'x' } },
			{ retries: { code: 'INTEGER', value: '1.5' }, label: { code: 'SINGLE', value: [ 'a', 'b' ] } },
		], [ codes(res.errors.collectors.wifi), codes(res.errors.collectors.sampler) ]);
		assert.match([
			{ enabled: 'expected a boolean, got "maybe"', stations: 'expected a boolean, got "x"' },
			{ retries: 'expected an integer, got "1.5"', label: 'expected a single value, got [ "a", "b" ]' },
		], [ messages(res.errors.collectors.wifi), messages(res.errors.collectors.sampler) ]);
	});

	it('checks exec_timeout, and the timeout of collectors that run programs, which the others ignore', () => {
		assert.match({ ok: false, errors: {
			main: { exec_timeout: { code: 'RANGE', min: 1, max: 30, value: 0, message: 'expected an integer from 1 to 30, got 0' } },
			collectors: { nft_counters: { timeout: { code: 'INTEGER', value: '5s', message: 'expected an integer, got "5s"' } } },
		} }, validate({ main: { exec_timeout: '0' }, collectors: { nft_counters: { timeout: '5s' }, wifi: { timeout: 'whatever' } } }));
		assert.match(true, validate({ main: { exec_timeout: '30' }, collectors: { nft_counters: { timeout: '1' } } }).ok);
	});

	prop('refuses a timeout exactly when it is not 1 to 30 seconds', gen.int(-40, 40), (n) => {
		let res = validate({ collectors: { nft_counters: { timeout: '' + n } } });
		assert.match(n < 1 || n > 30, res.errors.collectors.nft_counters?.timeout != null);
	});

	it('takes an empty or missing value as unset, which is the default', () => {
		assert.match(true, validate({ main: { listen_port: '', listen_interface: null }, collectors: { sampler: { retries: '' } } }).ok);
	});

	it('ignores options nobody declared and collectors that are not installed, as the exporter does', () => {
		assert.match(true, validate({ main: { listen_addr: 'x' }, collectors: { wifi: { nope: 'x' }, ghost: { enabled: 'maybe' } } }).ok);
	});

	it('refuses malformed arguments', () => {
		assert.match([
			{ error: rpc_validate.ARGS_INVALID, message: 'main and collectors must be objects' },
			{ error: rpc_validate.ARGS_INVALID, message: 'main and collectors must be objects' },
			{ error: rpc_validate.ARGS_INVALID, message: 'collectors.wifi must be an object' },
		], [
			validate({ main: [ 'x' ] }),
			validate({ collectors: 'wifi' }),
			validate({ collectors: { wifi: '0' } }),
		]);
	});

	it('passes nothing at all', () => {
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate(null));
	});

	prop('refuses a boolean option exactly when the exporter cannot read it',
		gen.string({ charset: 'abdefilnorstuy01', min_len: 1, max_len: 8 }), (s) => {
			let res = validate({ collectors: { wifi: { stations: s } } });
			assert.match(!config.convert('stations', s, { default: true }).ok, res.errors.collectors.wifi?.stations != null);
		});

	prop('refuses every value with a code it knows, its arguments, and the English of them',
		gen.tuple(
			gen.elements(...validate_names()),
			gen.oneof(gen.string({ charset: '-019azy/.(*', min_len: 1, max_len: 6 }), gen.array(gen.elements('a', '1'), { min_len: 2, max_len: 2 }))), (t) => {
			let res = validate({ main: { [t[0]]: t[1] }, collectors: { sampler: { [t[0]]: t[1] }, nft_counters: { [t[0]]: t[1] } } });
			let refusals = [ ...values(res.errors.main), ...values(res.errors.collectors.sampler ?? {}), ...values(res.errors.collectors.nft_counters ?? {}) ];

			for (let r in refusals) {
				let c = config.PROBLEMS[r.code];
				let problem = { ...r };

				delete problem.message;
				assert.match(true, c != null, r.code);
				assert.match([], filter(keys(problem), (k) => k != 'code' && k != 'value' && !(k in c.args)), r.code);
				assert.match(config.english(problem), r.message);
			}
		});

	prop('refuses a port exactly when the init script would',
		gen.string({ charset: '-0123456789x', min_len: 1, max_len: 6 }), (s) => {
			let n = match(s, /^-?[0-9]+$/) ? int(s) : null;
			let res = validate({ main: { listen_port: s } });
			assert.match(n == null || n < 1 || n > 65535, res.errors.main.listen_port != null);
		});
});

describe('rpc_validate.validate.validate, basic auth', () => {
	// `uhttpd -m secret`.
	const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
	const TLS = { cert: '/etc/ssl/x.crt', key: '/etc/ssl/x.key' };

	function validate(main) {
		let out;

		with_sys({}, { collectors: [] }, (sys) => {
			out = rpc_validate.validate(sys, { main });
		});

		return out;
	}

	it('passes a user and a hash with cert and key', () => {
		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate({ auth_user: 'prom', auth_password: HASH, ...TLS }));
	});

	// What LuCI's settings check: a login allowed this app alone must not
	// have root copy /etc/shadow into the jail, or read /dev/zero forever.
	it('refuses a cert or key outside the TLS directories, and one there that is not a regular file of 64 KiB at most', () => {
		let out;

		assert.match({ cert: { code: 'TLS_PATH', value: '/etc/shadow' }, key: { code: 'TLS_PATH', value: '/dev/zero' } },
			codes(validate({ cert: '/etc/shadow', key: '/dev/zero' }).errors.main));

		with_sys({}, { collectors: [] }, (sys) => {
			sys.fs = {
				stat: (p) => ({ '/etc/ssl/zero.crt': { type: 'char', size: 0 }, '/etc/ssl/big.key': { type: 'file', size: 70000 } })[p],
				realpath: (p) => p,
			};
			out = rpc_validate.validate(sys, { main: { cert: '/etc/ssl/zero.crt', key: '/etc/ssl/big.key' } });
		});
		assert.match({
			cert: { code: 'TLS_FILE', max: 65536, value: '/etc/ssl/zero.crt' },
			key: { code: 'TLS_FILE', max: 65536, value: '/etc/ssl/big.key' },
		}, codes(out.errors.main));
	});

	it('refuses them without cert and key, on the user\'s field', () => {
		assert.match({ ok: false, errors: { main: {
			auth_user: { code: 'AUTH_NEEDS_TLS', message: 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear' },
		}, collectors: {} } }, validate({ auth_user: 'prom', auth_password: HASH, cert: TLS.cert }));
	});

	it('refuses a user without a hash given or saved, on the password\'s field; takes a hash without a user as no basic auth', () => {
		assert.match([
			{ auth_password: { code: 'AUTH_NEEDS_PASSWORD', message: 'basic auth needs the hash of a password along with auth_user' } },
			{},
		], [
			validate({ auth_user: 'prom', ...TLS }).errors.main,
			validate({ auth_password: HASH, ...TLS }).errors.main,
		]);
	});

	// The hash saved apart, which a client such as LuCI may not read.
	function validate_saved(main, hash) {
		let out;

		with_sys({}, { collectors: ALL, hash }, (sys) => {
			out = rpc_validate.validate(sys, { main });
		});

		return out;
	}

	it('checks a user given without a hash against the saved hash, and never answers it', () => {
		let over = crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX + 1);
		let refused = validate_saved({ auth_user: 'prom', ...TLS }, over);

		assert.match({ ok: true, errors: { main: {}, collectors: {} } }, validate_saved({ auth_user: 'prom', ...TLS }, HASH));
		assert.match({ auth_password: { code: 'CRYPT_ROUNDS', max: auth.ROUNDS_MAX } }, codes(refused.errors.main));
		assert.match([ -1, -1 ], [ index(sprintf('%J', refused), substr(over, -86)), index(sprintf('%J', validate_saved({ auth_user: 'prom', ...TLS }, HASH)), HASH) ]);
	});

	it('checks a hash given, a new one, in place of the saved one', () => {
		let over = crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX + 1);

		assert.match(true, validate_saved({ auth_user: 'prom', auth_password: HASH, ...TLS }, over).ok);
		assert.match(false, validate_saved({ auth_user: 'prom', auth_password: 'hunter2', ...TLS }, HASH).ok);
	});

	it('reads no saved hash without a user', () => {
		assert.match(true, validate_saved({ ...TLS }, 'not a hash').ok);
	});

	it('refuses a password that is not a crypt hash, and never says it', () => {
		let res = validate({ auth_user: 'prom', auth_password: 'hunter2', ...TLS });

		assert.match({ auth_password: { code: 'CRYPT', message: 'expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$' } }, res.errors.main);
		assert.match(false, 'value' in res.errors.main.auth_password);
		assert.match(-1, index(sprintf('%J', res), 'hunter2'));
	});

	it('refuses a hash of more rounds than basic auth takes, and never says it', () => {
		let over = crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX + 1);
		let res = validate({ auth_user: 'prom', auth_password: over, ...TLS });

		assert.match([ true, false ], [ validate({ auth_user: 'prom', auth_password: crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX), ...TLS }).ok, res.ok ]);
		assert.match({ auth_password: { code: 'CRYPT_ROUNDS', max: auth.ROUNDS_MAX } }, codes(res.errors.main));
		assert.match(true, index(res.errors.main.auth_password.message, `expected a hash of at most ${auth.ROUNDS_MAX} rounds`) == 0);
		assert.match(-1, index(sprintf('%J', res), substr(over, -86)));
	});

	it('takes an empty user and password as none', () => {
		assert.match(true, validate({ auth_user: '', auth_password: '' }).ok);
	});

	prop('refuses basic auth exactly when cert or key is missing',
		gen.tuple(gen.elements('', TLS.cert), gen.elements('', TLS.key)), (t) => {
			let main = { auth_user: 'prom', auth_password: HASH, cert: t[0], key: t[1] };

			assert.match(t[0] != '' && t[1] != '', validate(main).ok);
		});
});
