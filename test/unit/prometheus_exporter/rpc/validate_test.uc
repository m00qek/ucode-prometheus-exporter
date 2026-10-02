'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as rpc_validate from 'prometheus_exporter.rpc.validate';
import * as config from 'prometheus_exporter.config';
import * as crypt from 'prometheus_exporter.crypt';
import * as auth from 'prometheus_exporter.auth';
import { collector, ALL, with_sys } from 'lib.rpc';

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
			main: { enabled: '1', listen_interface: '*', listen_port: '9102', http_keepalive: '0', cert: '/etc/x.crt', key: '/etc/x.key', omit_zero_values: 'yes' },
			collectors: { wifi: { enabled: '0', stations: 'off' }, sampler: { retries: '-2', label: 'y' } },
		}));
	});

	it('says what the exporter would refuse of the main section, field by field', () => {
		assert.match({ ok: false, errors: { main: {
			listen_port: 'expected an integer from 1 to 65535, got 0',
			http_keepalive: 'expected an integer of 0 or more, got -1',
			omit_zero_values: 'expected a boolean, got "maybe"',
			enabled: 'expected a boolean, got "2"',
		}, collectors: {} } }, validate({
			main: { listen_port: '0', http_keepalive: '-1', omit_zero_values: 'maybe', enabled: '2', listen_interface: 'lan' },
		}));
	});

	it('says what the exporter would refuse of a collector\'s options and its enabled switch', () => {
		assert.match({ ok: false, errors: { main: {}, collectors: {
			wifi: { enabled: 'expected a boolean, got "maybe"', stations: 'expected a boolean, got "x"' },
			sampler: { retries: 'expected an integer, got "1.5"', label: 'expected a single value, got [ "a", "b" ]' },
		} } }, validate({
			collectors: { wifi: { enabled: 'maybe', stations: 'x' }, sampler: { retries: '1.5', label: [ 'a', 'b' ], verbose: '1' } },
		}));
	});

	it('checks exec_timeout, and the timeout of collectors that run programs, which the others ignore', () => {
		assert.match({ ok: false, errors: {
			main: { exec_timeout: 'expected an integer from 1 to 30, got 0' },
			collectors: { nft_counters: { timeout: 'expected an integer, got "5s"' } },
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
	const TLS = { cert: '/etc/x.crt', key: '/etc/x.key' };

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

	it('refuses them without cert and key, on the user\'s field', () => {
		assert.match({ ok: false, errors: { main: {
			auth_user: 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
		}, collectors: {} } }, validate({ auth_user: 'prom', auth_password: HASH, cert: TLS.cert }));
	});

	it('refuses half of it, on the field that is missing', () => {
		assert.match([
			{ auth_password: 'basic auth needs the hash of a password along with auth_user' },
			{ auth_user: 'basic auth needs a user along with auth_password' },
		], [
			validate({ auth_user: 'prom', ...TLS }).errors.main,
			validate({ auth_password: HASH, ...TLS }).errors.main,
		]);
	});

	it('refuses a password that is not a crypt hash, and never says it', () => {
		let res = validate({ auth_user: 'prom', auth_password: 'hunter2', ...TLS });

		assert.match({ auth_password: 'expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$' }, res.errors.main);
		assert.match(-1, index(sprintf('%J', res), 'hunter2'));
	});

	it('refuses a hash of more rounds than basic auth takes, and never says it', () => {
		let over = crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX + 1);
		let res = validate({ auth_user: 'prom', auth_password: over, ...TLS });

		assert.match([ true, false ], [ validate({ auth_user: 'prom', auth_password: crypt.sha_crypt('6', 'secret', 'saltsalt', auth.ROUNDS_MAX), ...TLS }).ok, res.ok ]);
		assert.match(true, index(res.errors.main.auth_password, `expected a hash of at most ${auth.ROUNDS_MAX} rounds`) == 0);
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
