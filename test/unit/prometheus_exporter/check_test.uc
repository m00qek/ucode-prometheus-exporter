'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as check from 'prometheus_exporter.check';
import * as loader from 'prometheus_exporter.loader';
import * as deps from 'prometheus_exporter.deps';
import * as jail from 'prometheus_exporter.jail';
import * as config from 'prometheus_exporter.config';
import * as Result from 'prometheus_exporter.result';
import { with_mods } from 'context';

function collector(name, collect, meta) {
	let res = loader.validate(loader.id_of(name), { meta: { name, title: 'Test', help: 'Test.', needs: [], ...meta }, collect });

	if (!res.ok)
		die(Result.describe(res));

	return res.data;
}

const OK = collector('loadavg', () => Result.ok(), { needs: [ 'fs' ] });
const FAILING = collector('openwrt', () => Result.err('UBUS_CALL_FAILED', 'system board: Not found'), { needs: [ 'ubus' ] });
const TEXTFILE = collector('textfile', () => Result.ok(), { needs: [ 'fs' ], options: { directory: { default: '/var/prometheus', datatype: 'directory', help: 'Where.' } }, paths: [ '{directory}' ] });
const NFT = collector('nft-counters', () => Result.ok(), { needs: [ 'exec' ], commands: [ 'nft' ] });
const IDLE = collector('dnsmasq', () => Result.none('dnsmasq is disabled'), { needs: [ 'ubus' ] });

// `uhttpd -m secret`.
const HASH = '$1$$ysVNzQc4CTMkp5daOdZ.3/';

// check.run over the mocks: `own` is the exporter's config, `files` the regular
// files stat finds.
function run(own, collectors, opts, files, skipped) {
	let out;

	with_mods({ uci: { data: { [config.NAME]: own } } }, (mods) => {
		let quiet = () => null;

		out = check.run({
			uci: mods.uci.cursor(),
			fs: { stat: (p) => p in (files ?? []) ? { type: 'file' } : null },
			path: jail.PATH,
			collectors,
			skipped,
			env: { session: () => deps.session({ ...mods, log: quiet }), clock: () => [ 0, 0 ], log: quiet },
		}, opts);
	});

	return { ok: out.ok, lines: split(out.report, '\n') };
}

describe('check.run --config', () => {
	it('passes a missing config: every option has its default', () => {
		assert.match({ ok: true, lines: [
			'ok   main: HTTP on interface loopback, port 9100, keepalive 70s, exec_timeout 5s, gzip when asked',
			'ok   collectors: 2 installed collectors, their options valid',
		] }, run({}, [ OK, TEXTFILE ], { config_only: true }));
	});

	it('fails an invalid main section, saying what is wrong', () => {
		let r = run({ main: { '.type': config.NAME, listen_port: '70000', omit_zero_values: 'maybe' } }, [ OK ], { config_only: true });

		assert.match(false, r.ok);
		assert.match(contains([
			'FAIL main: CONFIG_INVALID (listen_port: expected an integer from 1 to 65535, got 70000)',
			'FAIL main: CONFIG_INVALID (omit_zero_values: expected a boolean, got "maybe")',
		]), r.lines);
	});

	it('fails a collector section with an invalid option or enabled', () => {
		let own = {
			textfile: { '.type': 'collector', directory: [ 'a', 'b' ] },
			loadavg: { '.type': 'collector', enabled: 'maybe' },
		};
		let r = run(own, [ OK, TEXTFILE ], { config_only: true });

		assert.match(false, r.ok);
		assert.match([
			'ok   main: HTTP on interface loopback, port 9100, keepalive 70s, exec_timeout 5s, gzip when asked',
			'FAIL collector loadavg, section \'loadavg\': CONFIG_INVALID (enabled: expected a boolean, got "maybe")',
			'FAIL collector textfile, section \'textfile\': CONFIG_INVALID (directory: expected a single value, got [ "a", "b" ])',
		], r.lines);
	});

	it('warns of sections no installed collector has, and of collectors the loader skipped', () => {
		let own = {
			'ltq_dsl': { '.type': 'collector', enabled: '0' },
			cfg0a1b2c: { '.type': 'collector', '.anonymous': true },
		};
		let r = run(own, [ OK ], { config_only: true }, [], [ 'skipping collector: COLLECTOR_INVALID (odd: exports no meta)' ]);

		assert.match(true, r.ok);
		assert.match(contains([
			'warn skipping collector: COLLECTOR_INVALID (odd: exports no meta)',
			'warn section \'ltq_dsl\' names no installed collector; it is ignored',
			'warn an unnamed collector section is ignored: name it after its collector\'s module',
		]), r.lines);
	});

	it('warns of TLS options the init script cannot use', () => {
		let tls = (cert, key) => ({ main: { '.type': config.NAME, cert, ...(key ? { key } : {}) } });

		assert.match(contains([ 'warn main: cert and key go together; with only cert, it serves HTTP' ]),
			run(tls('/etc/x.crt', null), [], { config_only: true }).lines);
		assert.match(contains([ 'warn main: /etc/x.key is missing; it serves HTTP until it is there' ]),
			run(tls('/etc/x.crt', '/etc/x.key'), [], { config_only: true }, [ '/etc/x.crt' ]).lines);
		assert.match(contains([ 'ok   main: HTTPS on interface loopback, port 9100, keepalive 70s, exec_timeout 5s, gzip when asked' ]),
			run(tls('/etc/x.crt', '/etc/x.key'), [], { config_only: true }, [ '/etc/x.crt', '/etc/x.key' ]).lines);
	});

	it('says basic auth is on, with its user and never its hash, and compress off', () => {
		let main = { '.type': config.NAME, cert: '/etc/x.crt', key: '/etc/x.key', auth_user: 'prom', auth_password: HASH, compress: '0' };
		let r = run({ main }, [], { config_only: true }, [ '/etc/x.crt', '/etc/x.key' ]);

		assert.match(true, r.ok);
		assert.match(contains([ 'ok   main: HTTPS on interface loopback, port 9100, keepalive 70s, basic auth as user "prom", exec_timeout 5s, no compression (option compress)' ]),
			r.lines);
		assert.match(-1, index(join('\n', r.lines), HASH));
	});

	it('fails basic auth without cert and key, and with one that is missing: it would serve HTTP', () => {
		let main = { '.type': config.NAME, auth_user: 'prom', auth_password: HASH };
		let without = run({ main }, [], { config_only: true });
		let missing = run({ main: { ...main, cert: '/etc/x.crt', key: '/etc/x.key' } }, [], { config_only: true }, [ '/etc/x.crt' ]);

		assert.match([ false, false ], [ without.ok, missing.ok ]);
		assert.match(contains([ 'FAIL main: CONFIG_INVALID (auth_user: basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear)' ]),
			without.lines);
		assert.match(contains([ 'FAIL main: /etc/x.key is missing; basic auth takes HTTPS only, so the service does not start until it is there' ]),
			missing.lines);
	});

	it('fails half of basic auth, and a password that is not a hash, without saying it', () => {
		let tls = { '.type': config.NAME, cert: '/etc/x.crt', key: '/etc/x.key' };
		let files = [ '/etc/x.crt', '/etc/x.key' ];

		assert.match([
			'FAIL main: CONFIG_INVALID (auth_password: basic auth needs the hash of a password along with auth_user)',
			'FAIL main: CONFIG_INVALID (auth_password: expected a crypt hash: $1$ (uhttpd -m), $5$ or $6$)',
		], [
			run({ main: { ...tls, auth_user: 'prom' } }, [], { config_only: true }, files).lines[0],
			run({ main: { ...tls, auth_user: 'prom', auth_password: 'hunter2' } }, [], { config_only: true }, files).lines[0],
		]);
	});

	it('says when the service is disabled', () => {
		assert.match(contains([ 'ok   main: disabled (option enabled), HTTP on every address, port 9100, keepalive 0s, exec_timeout 5s, gzip when asked' ]),
			run({ main: { '.type': config.NAME, enabled: '0', listen_interface: '*', http_keepalive: '0' } }, [], { config_only: true }).lines);
	});
});

describe('check.run', () => {
	it('lists each collector with what the jail gives it, runs a scrape and reports what failed', () => {
		let own = { textfile: { '.type': 'collector', directory: '/srv/prom' }, openwrt: { '.type': 'collector' } };
		let r = run(own, [ OK, NFT, FAILING, TEXTFILE ], {}, [ '/usr/sbin/nft', '/srv/prom' ]);

		assert.match(true, r.ok);
		assert.match([
			'ok   main: HTTP on interface loopback, port 9100, keepalive 70s, exec_timeout 5s, gzip when asked',
			'ok   collectors: 4 installed collectors, their options valid',
			'warn scrape, outside the jail: 3 of 4 collectors succeeded',
			'warn scrape: openwrt: UBUS_CALL_FAILED (system board: Not found)',
			'',
			'collectors: 4 installed, 4 enabled',
			'  loadavg (Test): section \'loadavg\', enabled',
			'      needs    fs',
			'  nft-counters (Test): section \'nft_counters\', enabled',
			'      timeout  5s # the main section\'s exec_timeout',
			'      needs    exec',
			'      commands nft=/usr/sbin/nft',
			'      mounts   /bin/sh /usr/sbin/nft',
			'  openwrt (Test): section \'openwrt\', enabled',
			'      needs    ubus',
			'  textfile (Test): section \'textfile\', enabled',
			'      option   directory="/srv/prom" # Where.',
			'      needs    fs',
			'      paths    /srv/prom',
			'      mounts   /srv/prom',
			'',
			'jail mounts:',
			'  /bin/sh',
			'  /etc/config/prometheus-exporter',
			'  /srv/prom',
			'  /usr/sbin/nft',
		], r.lines);
	});

	it('says which collectors have nothing to observe, and why, as successes', () => {
		let r = run({}, [ OK, IDLE, FAILING ], {});

		assert.match(true, r.ok);
		assert.match([
			'warn scrape, outside the jail: 2 of 3 collectors succeeded, 1 with nothing to observe',
			'warn scrape: openwrt: UBUS_CALL_FAILED (system board: Not found)',
			'ok   scrape: dnsmasq has nothing to observe: dnsmasq is disabled',
		], filter(r.lines, (l) => index(l, ' scrape') == 4));
		assert.match(contains([ 'ok   scrape, outside the jail: 2 of 2 collectors succeeded, 1 with nothing to observe' ]),
			run({}, [ OK, IDLE ], {}).lines);
	});

	it('leaves a disabled collector out of the scrape and the jail, and says what the jail cannot give', () => {
		let r = run({ openwrt: { '.type': 'collector', enabled: '0' } }, [ OK, NFT, FAILING ], {});

		assert.match(contains([
			'warn jail: nft-counters: command nft is not on /usr/sbin:/usr/bin:/sbin:/bin',
			'ok   scrape, outside the jail: 2 of 2 collectors succeeded',
			'collectors: 3 installed, 2 enabled',
			'      commands nft=(not found)',
			'  openwrt (Test): section \'openwrt\', disabled',
		]), r.lines);
		assert.match([ '  /bin/sh', '  /etc/config/prometheus-exporter' ], slice(r.lines, -2));
	});

	it('warns of a path that is not there, as the jail leaves it out', () => {
		assert.match(contains([ 'warn jail: textfile: /var/prometheus is not there; the service mounts it once it is' ]),
			run({}, [ TEXTFILE ], {}).lines);
		assert.match([], filter(run({ textfile: { '.type': 'collector', enabled: '0' } }, [ TEXTFILE ], {}).lines, (l) => index(l, 'not there') >= 0));
	});

	it('says which directories the service makes, and does not warn of them', () => {
		let owner = collector('owner', () => Result.ok(), {
			needs: [ 'fs' ], options: { directory: { default: '/var/own', datatype: 'directory', help: 'Where.' } },
			paths: [ { path: '{directory}', owned: true } ],
		});
		let r = run({}, [ owner ], {});

		assert.match(contains([ '      paths    /var/own', '      makes    /var/own', '      mounts   /var/own' ]), r.lines);
		assert.match([], filter(r.lines, (l) => index(l, 'not there') >= 0));
	});

	it('says how many seconds each collector that runs programs gets, and where they come from', () => {
		let radio = collector('ubnt-manager', () => Result.ok(), { needs: [ 'exec' ], commands: [ 'ubnt-manager' ], timeout: 12 });
		let timeouts = (own) => filter(run(own, [ OK, NFT, radio ], {}).lines, (l) => index(l, ' timeout ') >= 0);

		assert.match([
			'      timeout  5s # the main section\'s exec_timeout',
			'      timeout  12s # the collector\'s own (meta.timeout)',
		], timeouts({}));
		assert.match([
			'      timeout  8s # the main section\'s exec_timeout',
			'      timeout  3s # its section\'s option timeout',
		], timeouts({ main: { '.type': config.NAME, exec_timeout: '8' }, ubnt_manager: { '.type': 'collector', timeout: '3' } }));
	});

	it('fails a timeout or an exec_timeout that is not 1 to 30 seconds, and ignores timeout where no program runs', () => {
		let r = run({
			main: { '.type': config.NAME, exec_timeout: '60' },
			nft_counters: { '.type': 'collector', timeout: '0' },
			loadavg: { '.type': 'collector', timeout: 'whatever' },
		}, [ OK, NFT ], { config_only: true });

		assert.match(false, r.ok);
		assert.match([
			'FAIL main: CONFIG_INVALID (exec_timeout: expected an integer from 1 to 30, got 60)',
			'FAIL collector nft-counters, section \'nft_counters\': CONFIG_INVALID (timeout: expected an integer from 1 to 30, got 0)',
		], r.lines);
	});

	prop('fails exactly when a collector\'s enabled is not a boolean',
		gen.elements('1', '0', 'yes', 'off', 'maybe', '2', ''), (v) => {
			let r = run({ loadavg: { '.type': 'collector', enabled: v } }, [ OK ], { config_only: true });
			assert.match(v in [ '1', '0', 'yes', 'off' ], r.ok);
		});
});

describe('check.status', () => {
	it('says where uhttpd listens and how many collectors it serves', () => {
		with_mods({ uci: { data: { [config.NAME]: { openwrt: { '.type': 'collector', enabled: '0' } } } } }, (mods) => {
			let cmd = [ '/usr/sbin/uhttpd', '-f', '-o', '/metrics', '-k', '70', '-p', '127.0.0.1:9100', '-p', '[::1]:9100' ];

			assert.match('listening on http://127.0.0.1:9100/metrics, http://[::1]:9100/metrics, gzip when asked, serving 2 collectors',
				check.status(cmd, [ OK, NFT, FAILING ], mods.uci.cursor()));
		});
	});

	it('says when a scrape logs in, by uhttpd\'s config file, and when compress is off', () => {
		with_mods({ uci: { data: { [config.NAME]: { main: { '.type': config.NAME, compress: '0' } } } } }, (mods) => {
			let cmd = [ '/usr/sbin/uhttpd', '-f', '-c', '/var/run/prometheus-exporter/uhttpd.conf', '-r', 'prometheus-exporter', '-s', '9100' ];

			assert.match('listening on https://*:9100/metrics, basic auth, serving 1 collector',
				check.status(cmd, [ OK ], mods.uci.cursor()));
		});
	});

	it('reads basic auth off uhttpd\'s command line: a config file other than /dev/null', () => {
		assert.match([ true, false, false ], [
			check.logs_in([ 'uhttpd', '-c', '/var/run/x.conf', '-p', '1' ]),
			check.logs_in([ 'uhttpd', '-c', '/dev/null', '-p', '1' ]),
			check.logs_in([ 'uhttpd', '-p', '1', '-c' ]),
		]);
	});

	it('tells uhttpd from the watch instance beside it', () => {
		let uhttpd = { running: true, command: [ '/usr/sbin/uhttpd', '-p', '9100' ] };
		let watch = { running: true, command: [ '/usr/libexec/prometheus-exporter/watch.uc', '/var/lib/unbound' ] };

		assert.match([ [ uhttpd ], [], [] ], [ check.exporters([ watch, uhttpd ]), check.exporters([ watch ]), check.exporters(null) ]);
	});

	it('reads HTTPS and a bare port', () => {
		assert.match([ 'https://*:9100/metrics' ], check.listening([ 'uhttpd', '-C', 'c', '-K', 'k', '-s', '9100' ]));
		assert.match([], check.listening([ 'uhttpd', '-p' ]));
	});
});
