'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import * as check from 'node_exporter.check';
import * as loader from 'node_exporter.loader';
import * as deps from 'node_exporter.deps';
import * as jail from 'node_exporter.jail';
import * as config from 'node_exporter.config';
import * as Result from 'node_exporter.result';
import { with_mods } from 'context';

function collector(name, collect, meta) {
	let res = loader.validate(loader.id_of(name), { meta: { name, help: 'Test.', needs: [], ...meta }, collect });

	if (!res.ok)
		die(Result.describe(res));

	return res.data;
}

const OK = collector('loadavg', () => Result.ok(), { needs: [ 'fs' ] });
const FAILING = collector('openwrt', () => Result.err('UBUS_CALL_FAILED', 'system board: Not found'), { needs: [ 'ubus' ] });
const TEXTFILE = collector('textfile', () => Result.ok(), { needs: [ 'fs' ], options: { directory: '/var/prometheus' }, paths: [ '{directory}' ] });
const NFT = collector('nft-counters', () => Result.ok(), { needs: [ 'exec' ], commands: [ 'nft' ] });

// check.run over the mocks: `own` is the exporter's config, `files` the regular
// files stat finds.
function run(own, collectors, opts, files, skipped) {
	let out;

	with_mods({ uci: { data: { [config.PACKAGE]: own } } }, (mods) => {
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
			'ok   main: HTTP on interface loopback, port 9101, keepalive 70s',
			'ok   collectors: 2 installed collectors, their options valid',
		] }, run({}, [ OK, TEXTFILE ], { config_only: true }));
	});

	it('fails an invalid main section, saying what is wrong', () => {
		let r = run({ main: { '.type': config.PACKAGE, listen_port: '70000', omit_zero_values: 'maybe' } }, [ OK ], { config_only: true });

		assert.match(false, r.ok);
		assert.match(contains([
			'FAIL main: CONFIG_INVALID (listen_port: expected a port from 1 to 65535, got 70000)',
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
			'ok   main: HTTP on interface loopback, port 9101, keepalive 70s',
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
		let tls = (cert, key) => ({ main: { '.type': config.PACKAGE, cert, ...(key ? { key } : {}) } });

		assert.match(contains([ 'warn main: cert and key go together; with only cert, it serves HTTP' ]),
			run(tls('/etc/x.crt', null), [], { config_only: true }).lines);
		assert.match(contains([ 'warn main: /etc/x.key is missing; it serves HTTP until it is there' ]),
			run(tls('/etc/x.crt', '/etc/x.key'), [], { config_only: true }, [ '/etc/x.crt' ]).lines);
		assert.match(contains([ 'ok   main: HTTPS on interface loopback, port 9101, keepalive 70s' ]),
			run(tls('/etc/x.crt', '/etc/x.key'), [], { config_only: true }, [ '/etc/x.crt', '/etc/x.key' ]).lines);
	});

	it('says when the service is disabled', () => {
		assert.match(contains([ 'ok   main: disabled (option enabled), HTTP on every address, port 9101, keepalive 0s' ]),
			run({ main: { '.type': config.PACKAGE, enabled: '0', listen_interface: '*', http_keepalive: '0' } }, [], { config_only: true }).lines);
	});
});

describe('check.run', () => {
	it('lists each collector with what the jail gives it, runs a scrape and reports what failed', () => {
		let own = { textfile: { '.type': 'collector', directory: '/srv/prom' }, openwrt: { '.type': 'collector' } };
		let r = run(own, [ OK, NFT, FAILING, TEXTFILE ], {}, [ '/usr/sbin/nft', '/srv/prom' ]);

		assert.match(true, r.ok);
		assert.match([
			'ok   main: HTTP on interface loopback, port 9101, keepalive 70s',
			'ok   collectors: 4 installed collectors, their options valid',
			'warn scrape, outside the jail: 3 of 4 collectors succeeded',
			'warn scrape: openwrt: UBUS_CALL_FAILED (system board: Not found)',
			'',
			'collectors: 4 installed, 4 enabled',
			'  loadavg: section \'loadavg\', enabled',
			'      needs    fs',
			'  nft-counters: section \'nft_counters\', enabled',
			'      needs    exec',
			'      commands nft=/usr/sbin/nft',
			'      mounts   /bin/sh /usr/sbin/nft',
			'  openwrt: section \'openwrt\', enabled',
			'      needs    ubus',
			'  textfile: section \'textfile\', enabled',
			'      options  directory="/srv/prom"',
			'      needs    fs',
			'      paths    /srv/prom',
			'      mounts   /srv/prom',
			'',
			'jail mounts:',
			'  /bin/sh',
			'  /etc/config/prometheus-node-exporter-ucode',
			'  /srv/prom',
			'  /usr/sbin/nft',
		], r.lines);
	});

	it('leaves a disabled collector out of the scrape and the jail, and says what the jail cannot give', () => {
		let r = run({ openwrt: { '.type': 'collector', enabled: '0' } }, [ OK, NFT, FAILING ], {});

		assert.match(contains([
			'warn jail: nft-counters: command nft is not on /usr/sbin:/usr/bin:/sbin:/bin',
			'ok   scrape, outside the jail: 2 of 2 collectors succeeded',
			'collectors: 3 installed, 2 enabled',
			'      commands nft=(not found)',
			'  openwrt: section \'openwrt\', disabled',
		]), r.lines);
		assert.match([ '  /bin/sh', '  /etc/config/prometheus-node-exporter-ucode' ], slice(r.lines, -2));
	});

	it('warns of a path that is not there, as the jail leaves it out', () => {
		assert.match(contains([ 'warn jail: textfile: /var/prometheus is not there; it is mounted at the first start after it is' ]),
			run({}, [ TEXTFILE ], {}).lines);
		assert.match([], filter(run({ textfile: { '.type': 'collector', enabled: '0' } }, [ TEXTFILE ], {}).lines, (l) => index(l, 'not there') >= 0));
	});

	prop('fails exactly when a collector\'s enabled is not a boolean',
		gen.elements('1', '0', 'yes', 'off', 'maybe', '2', ''), (v) => {
			let r = run({ loadavg: { '.type': 'collector', enabled: v } }, [ OK ], { config_only: true });
			assert.match(v in [ '1', '0', 'yes', 'off' ], r.ok);
		});
});

describe('check.status', () => {
	it('says where uhttpd listens and how many collectors it serves', () => {
		with_mods({ uci: { data: { [config.PACKAGE]: { openwrt: { '.type': 'collector', enabled: '0' } } } } }, (mods) => {
			let cmd = [ '/usr/sbin/uhttpd', '-f', '-o', '/metrics', '-k', '70', '-p', '127.0.0.1:9101', '-p', '[::1]:9101' ];

			assert.match('listening on http://127.0.0.1:9101/metrics, http://[::1]:9101/metrics, serving 2 collectors',
				check.status(cmd, [ OK, NFT, FAILING ], mods.uci.cursor()));
		});
	});

	it('reads HTTPS and a bare port', () => {
		assert.match([ 'https://*:9101/metrics' ], check.listening([ 'uhttpd', '-C', 'c', '-K', 'k', '-s', '9101' ]));
		assert.match([], check.listening([ 'uhttpd', '-p' ]));
	});
});
