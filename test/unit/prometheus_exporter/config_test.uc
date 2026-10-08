'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as config from 'prometheus_exporter.config';
import * as crypt from 'prometheus_exporter.crypt';
import * as auth_mod from 'prometheus_exporter.auth';

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

function err_details(res) {
	return res.ok ? null : `${res.error}: ${res.details}`;
}

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

	it('takes the main section read already, as a scrape reads it once for all its collectors', () => {
		let main = { '.type': config.NAME, exec_timeout: '9', collector_budget: '7', max_samples: '300' };

		with_uci({ main, c: { '.type': 'collector', stations: '0' } }, (uci) => {
			let read = config.main(uci);

			assert.match(config.settings(uci, 'c', EXEC), config.settings(uci, 'c', EXEC, read));
			assert.match({ enabled: true, timeout: 9, budget: 10, max_samples: 300, options: { stations: false } }, config.settings(uci, 'c', EXEC, read).data);
		});

		// What was read is what counts: a main section that is not valid
		// gives the defaults, as it does read here.
		with_uci({ main: { ...main, exec_timeout: 'x' } }, (uci) => {
			assert.match(config.settings(uci, 'c', EXEC), config.settings(uci, 'c', EXEC, config.main(uci)));
			assert.match(config.EXEC_TIMEOUT, config.settings(uci, 'c', EXEC, config.main(uci)).data.timeout);
		});
	});

	it('reads the main section once, or not at all when given it: a scrape reads it once for every collector', () => {
		let reads = [];
		let sections = { main: { '.type': config.NAME, collector_budget: '7' }, c: { '.type': 'collector' } };
		let uci = { get_all: function(name, section) { push(reads, section); return sections[section]; } };

		config.settings(uci, 'c', EXEC);
		assert.match(1, length(filter(reads, (s) => s == 'main')));

		let main = config.main(uci);

		reads = [];
		assert.match(7, config.settings(uci, 'c', EXEC, main).data.budget);
		assert.match([], filter(reads, (s) => s == 'main'));
	});

	it('gives enabled, the timeout and the options apart', () => {
		with_uci({ c: { '.type': 'collector', enabled: '0', stations: '0', timeout: '7' } }, (uci) => {
			assert.match({ enabled: false, timeout: 7, budget: 8, max_samples: config.MAX_SAMPLES, options: { stations: false } }, config.settings(uci, 'c', EXEC).data);
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
	it('gives every collector enabled and budget, and one that runs programs timeout too', () => {
		assert.match([ 'enabled', 'budget', 'max_samples' ], keys(config.core(meta({}, [ 'fs', 'ubus' ]), 5)));
		assert.match({ enabled: config.ENABLED, timeout: { default: 9, ...config.TIMEOUT }, budget: { default: 12, ...config.BUDGET },
			max_samples: { default: 300, ...config.SAMPLES } }, config.core(meta({}, [ 'exec' ]), 9, 12, 300));
		assert.match([ config.COLLECTOR_BUDGET, config.MAX_SAMPLES ],
			[ config.core(meta({}, [ 'fs' ])).budget.default, config.core(meta({}, [ 'fs' ])).max_samples.default ]);
	});

	it('reserves the names of its options', () => {
		assert.match(config.RESERVED, keys(config.core(meta({}, [ 'exec' ]), 5)));
		assert.match('range(1,30)', config.TIMEOUT.datatype);
	});
});

describe('config max_samples', () => {
	function samples(m, main, own) {
		let out;
		let sections = { c: { '.type': 'collector', ...(own != null ? { max_samples: own } : {}) } };

		if (main != null)
			sections.main = { '.type': config.NAME, max_samples: main };
		with_uci(sections, (uci) => {
			let res = config.settings(uci, 'c', m);
			out = res.ok ? res.data.max_samples : `${res.error} (${res.details})`;
		});
		return out;
	}

	it('takes the section\'s max_samples, then meta.max_samples, then the main section\'s', () => {
		assert.match([ config.MAX_SAMPLES, 500, 70000, 7, 7 ], [
			samples(meta({}, [ 'fs' ])),
			samples(meta({}, [ 'fs' ]), '500'),
			samples(meta({}, [ 'fs' ], { max_samples: 70000 }), '500'),
			samples(meta({}, [ 'fs' ], { max_samples: 70000 }), '500', '7'),
			samples(meta({}, [ 'fs' ]), null, '7'),
		]);
	});

	it('refuses one of none, or past the most the core allows', () => {
		assert.match(`CONFIG_INVALID (max_samples: expected an integer from 1 to ${config.MAX_SAMPLES_MAX}, got 0)`, samples(meta({}, [ 'fs' ]), null, '0'));
		assert.match(true, index(samples(meta({}, [ 'fs' ]), null, `${config.MAX_SAMPLES_MAX + 1}`), 'CONFIG_INVALID (max_samples') == 0);
	});
});

describe('config budget', () => {
	const EXEC = meta({}, [ 'exec' ]);

	function budget(m, main, own) {
		let out;
		let sections = { c: { '.type': 'collector', ...(own != null ? { budget: own } : {}) } };

		if (main != null)
			sections.main = { '.type': config.NAME, collector_budget: main };
		with_uci(sections, (uci) => {
			let res = config.settings(uci, 'c', m);
			out = res.ok ? [ res.data.budget, config.budget_source(uci, 'c', res.data.timeout) ] : `${res.error} (${res.details})`;
		});
		return out;
	}

	it('takes the section\'s budget, then collector_budget, then a timeout and a second more when that is longer', () => {
		assert.match([
			[ config.COLLECTOR_BUDGET, 'collector_budget' ],
			[ 20, 'collector_budget' ],
			[ 2, 'budget' ],
			[ config.EXEC_TIMEOUT + 1, 'timeout' ],
			[ 13, 'timeout' ],
			[ 20, 'collector_budget' ],
		], [
			budget(meta({}, [ 'fs' ])),
			budget(meta({}, [ 'fs' ]), '20'),
			budget(meta({}, [ 'fs' ]), '20', '2'),
			budget(EXEC),
			budget(meta({}, [ 'exec' ], { timeout: 12 })),
			budget(EXEC, '20'),
		]);
	});

	it('refuses a budget that is not 1 to 60 seconds', () => {
		assert.match('CONFIG_INVALID (budget: expected an integer from 1 to 60, got 61)', budget(meta({}, [ 'fs' ]), null, '61'));
		assert.match('CONFIG_INVALID (budget: expected an integer from 1 to 60, got 0)', budget(meta({}, [ 'fs' ]), null, '0'));
	});

	prop('never quarantines what a timeout allows', gen.tuple(gen.int(1, 30), gen.int(1, 60)), (t) => {
		let b = budget(meta({}, [ 'exec' ], { timeout: t[0] }), `${t[1]}`);

		assert.match(true, b[0] >= t[0] + 1 && b[0] >= t[1]);
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
			assert.match({ omit_zero_values: true, compress: true, exec_timeout: config.EXEC_TIMEOUT, scrape_timeout: config.SCRAPE_TIMEOUT,
				collector_budget: config.COLLECTOR_BUDGET, max_samples: config.MAX_SAMPLES, max_scrape_samples: config.MAX_SCRAPE_SAMPLES }, config.main(uci).data);
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
		assert.match({ enabled: true, listen_interface: 'loopback', listen_port: 9100, http_keepalive: 70, cert: '', key: '', auth_user: '', auth_password: '',
			memory_limit: 0 }, service(null));
	});

	it('reads the options, typed', () => {
		assert.match({ enabled: false, listen_interface: '*', listen_port: 9100, http_keepalive: 0, cert: '/etc/x.crt', key: '', auth_user: '', auth_password: '',
			memory_limit: 48 }, service({ enabled: '0', listen_interface: '*', listen_port: '9100', http_keepalive: '0', cert: '/etc/x.crt', memory_limit: '48' }));
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

// `uhttpd -m secret`, and a $6$ hash.
const MD5 = '$1$$ysVNzQc4CTMkp5daOdZ.3/';
const SHA512 = crypt.sha_crypt('6', 'secret', 'saltsalt', 1000);
const TLS = { cert: '/etc/uhttpd.crt', key: '/etc/uhttpd.key' };

// A $5$ or $6$ hash, by its form, of these rounds.
function sha_form(rounds) {
	return gen.map(gen.tuple(gen.elements('5', '6'), rounds,
		gen.string({ min_len: 0, max_len: 16, charset: crypt.ITOA64 }), gen.string({ len: 86, charset: crypt.ITOA64 })),
		(t) => '$' + t[0] + '$' + (t[1] != null ? 'rounds=' + t[1] + '$' : '') + t[2] + '$' + substr(t[3], 0, t[0] == '5' ? 43 : 86));
}

// Any hash of the formats basic auth takes, by its form: of at most its rounds.
const HASH = gen.oneof(
	gen.map(gen.tuple(gen.string({ min_len: 0, max_len: 8, charset: crypt.ITOA64 }), gen.string({ len: 22, charset: crypt.ITOA64 })),
		(t) => `$1$${t[0]}$${t[1]}`),
	sha_form(gen.int(crypt.ROUNDS_MIN, auth_mod.ROUNDS_MAX))
);

const USER = gen.string({ min_len: 1, max_len: 20, charset: 'abcXYZ019._-@' });

describe('config.service, basic auth', () => {
	function service(main) {
		let out;
		with_uci({ main: { '.type': config.NAME, ...main } }, (uci) => { out = config.service(uci); });
		return out.ok ? out.data : err_details(out);
	}

	function auth(main) {
		let out;
		with_uci({ main: { '.type': config.NAME, ...main } }, (uci) => { out = config.auth(uci); });
		return out.ok ? out.data : err_details(out);
	}

	it('takes a user and a crypt hash, with cert and key', () => {
		assert.match({ user: 'prom', hash: MD5 }, auth({ auth_user: 'prom', auth_password: MD5, ...TLS }));
		assert.match({ user: 'prom', hash: SHA512 }, auth({ auth_user: 'prom', auth_password: SHA512, ...TLS }));
	});

	it('is off without them, as before', () => {
		assert.match([ null, null ], [ auth({}), auth(TLS) ]);
	});

	it('refuses basic auth without cert or key', () => {
		let why = 'CONFIG_INVALID: auth_user: basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear';

		assert.match([ why, why, why ], [
			service({ auth_user: 'prom', auth_password: MD5 }),
			service({ auth_user: 'prom', auth_password: MD5, cert: TLS.cert }),
			service({ auth_user: 'prom', auth_password: MD5, key: TLS.key }),
		]);
	});

	it('refuses half of it: a user without a hash, or a hash without a user', () => {
		assert.match([
			'CONFIG_INVALID: auth_password: basic auth needs the hash of a password along with auth_user',
			'CONFIG_INVALID: auth_user: basic auth needs a user along with auth_password',
		], [
			service({ auth_user: 'prom', ...TLS }),
			service({ auth_password: MD5, ...TLS }),
		]);
	});

	it('refuses a password that is not a crypt hash, without saying it', () => {
		for (let v in [ 'secret', '$p$root', 'ab01FAX.bQRSU', '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy' ]) {
			let why = service({ auth_user: 'prom', auth_password: v, ...TLS });

			assert.match('CONFIG_INVALID: auth_password: expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$', why);
			assert.match(-1, index(why, v));
		}
	});

	it('takes a hash of the most rounds basic auth takes, and refuses one of a round more, saying why but not the hash', () => {
		let at = crypt.sha_crypt('6', 'secret', 'saltsalt', auth_mod.ROUNDS_MAX);
		let over = crypt.sha_crypt('6', 'secret', 'saltsalt', auth_mod.ROUNDS_MAX + 1);
		let why = service({ auth_user: 'prom', auth_password: over, ...TLS });

		assert.match({ user: 'prom', hash: at }, auth({ auth_user: 'prom', auth_password: at, ...TLS }));
		assert.match(`CONFIG_INVALID: auth_password: expected a hash of at most ${auth_mod.ROUNDS_MAX} rounds, ` +
			'which a scrape computes to check the password (hash_password makes one of 1000; one without rounds= has 5000)', why);
		assert.match([ -1, -1 ], [ index(why, over), index(why, substr(over, -86)) ]);
	});

	it('refuses a $5$ or $6$ hash that names no rounds, which has 5000', () => {
		let why = service({ auth_user: 'prom', auth_password: crypt.sha_crypt('5', 'secret', 'saltsalt', null), ...TLS });

		assert.match(true, index(why, `expected a hash of at most ${auth_mod.ROUNDS_MAX} rounds`) > 0);
	});

	prop('takes a $5$ or $6$ hash exactly when its rounds are within the cap, and never says it',
		sha_form(gen.oneof(gen.int(crypt.ROUNDS_MIN, crypt.ROUNDS_MAX), gen.int(auth_mod.ROUNDS_MAX - 2, auth_mod.ROUNDS_MAX + 2), gen.constant(null))),
		(h) => {
			let why = service({ auth_user: 'prom', auth_password: h, ...TLS });

			assert.match(crypt.rounds(h) <= auth_mod.ROUNDS_MAX, type(why) == 'object', h);
			if (type(why) == 'string')
				assert.match(-1, index(why, h));
		});

	it('never says a password given as a list either', () => {
		assert.match('CONFIG_INVALID: auth_password: expected a single value',
			service({ auth_user: 'prom', auth_password: [ 'secret', 'other' ], ...TLS }));
	});

	it('refuses a user with a ":", a space or nothing', () => {
		let why = 'CONFIG_INVALID: auth_user: expected a user of 1 to 64 characters, without ":", spaces or control characters';

		assert.match([ `${why}, got "a:b"`, `${why}, got "a b"`, `${why}, got ""` ],
			map([ 'a:b', 'a b', '' ], (u) => service({ auth_user: u, auth_password: MD5, ...TLS })));
	});

	prop('refuses basic auth without both cert and key, whatever else is set',
		gen.tuple(USER, HASH, gen.elements('', TLS.cert), gen.elements('', TLS.key), gen.elements('loopback', '*', 'lan'), gen.int(1, 65535)),
		(t) => {
			let main = { auth_user: t[0], auth_password: t[1], listen_interface: t[4], listen_port: '' + t[5] };

			if (t[2] != '')
				main.cert = t[2];
			if (t[3] != '')
				main.key = t[3];

			let why = service(main);

			assert.match(t[2] != '' && t[3] != '', type(why) == 'object', why);
			if (type(why) == 'string')
				assert.match(true, index(why, 'basic auth needs HTTPS') > 0);
		});

	prop('takes any crypt hash of the formats as auth_password', HASH, (h) => {
		assert.match({ user: 'prom', hash: h }, auth({ auth_user: 'prom', auth_password: h, ...TLS }));
	});

	prop('refuses any other text as auth_password, and never says it', gen.ascii({ min_len: 1, max_len: 120 }), (v) => {
		if (crypt.is_hash(v))
			return;

		assert.match('CONFIG_INVALID: auth_password: expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$',
			auth({ auth_user: 'prom', auth_password: v, ...TLS }), v);
	});
});

describe('config.together', () => {
	it('names the option each problem is with, by its code', () => {
		assert.match([
			{},
			{},
			{ auth_password: { code: 'AUTH_NEEDS_PASSWORD' } },
			{ auth_user: { code: 'AUTH_NEEDS_USER' }, auth_password: { code: 'AUTH_NEEDS_TLS' } },
		], [
			config.together({}),
			config.together({ auth_user: 'u', auth_password: MD5, ...TLS }),
			config.together({ auth_user: 'u', ...TLS }),
			config.together({ auth_password: MD5 }),
		]);
	});

	it('says each in English, as the init script and check do', () => {
		assert.match([
			'basic auth needs the hash of a password along with auth_user',
			'basic auth needs a user along with auth_password',
			'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear',
		], map([ config.together({ auth_user: 'u', ...TLS }).auth_password, ...values(config.together({ auth_password: MD5 })) ], config.english));
	});
});

describe('config.invalid', () => {
	it('holds the problem of a value an option does not take, with the value but for a secret\'s', () => {
		let res = config.invalid('listen_port', config.problem('RANGE', { min: 1, max: 65535 }), 0, config.SERVICE_OPTIONS.listen_port);
		let secret = config.invalid('auth_password', config.problem('CRYPT'), 'hunter2', config.SERVICE_OPTIONS.auth_password);

		assert.match({ ok: false, error: 'CONFIG_INVALID', details: 'listen_port: expected an integer from 1 to 65535, got 0',
			data: { option: 'listen_port', problem: { code: 'RANGE', min: 1, max: 65535, value: 0 } } }, res);
		assert.match([ 'auth_password: expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$', { option: 'auth_password', problem: { code: 'CRYPT' } } ],
			[ secret.details, secret.data ]);
		assert.match(-1, index(sprintf('%J', secret), 'hunter2'));
	});
});

describe('config.main, compress', () => {
	function main(v) {
		let out;
		with_uci({ main: { '.type': config.NAME, ...(v != null ? { compress: v } : {}) } }, (uci) => { out = config.main(uci); });
		return out.ok ? out.data.compress : err_details(out);
	}

	it('is on by default, and off with 0', () => {
		assert.match([ true, true, false, false ], map([ null, '1', '0', 'off' ], main));
	});

	it('refuses what is not a boolean', () => {
		assert.match('CONFIG_INVALID: compress: expected a boolean, got "gzip"', main('gzip'));
	});
});
