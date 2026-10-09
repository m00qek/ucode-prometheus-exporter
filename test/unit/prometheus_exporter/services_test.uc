'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as deps from 'prometheus_exporter.deps';
import * as services from 'prometheus_exporter.services';
import * as Result from 'prometheus_exporter.result';
import { rc } from 'prometheus_exporter.devkit.rc';

// cb(ubus channel, connection) over a strict ubus mock with this config.
function with_ubus(cfg, cb) {
	mock.inject('ubus', { strict: true, data: {}, ...cfg }, (ubus) => {
		let conns = [];
		let ch = deps.ubus_channel(() => { let c = ubus.connect(); push(conns, c); return c; });

		cb(ch, () => conns[0]);
	});
}

describe('services.state', () => {
	it('asks rc for the one script, without its running check', () => {
		with_ubus({ data: rc({ dnsmasq: true }) }, (ubus, conn) => {
			assert.match({ ok: true, data: 'enabled' }, { ok: true, data: services.state(ubus, 'dnsmasq').data });
			assert.match([ [ 'rc', 'list', { name: 'dnsmasq', skip_running_check: true } ] ], conn().__utest__.calls.call);
		});
	});

	it('tells an enabled script from a disabled one and from none', () => {
		with_ubus({ data: rc({ dnsmasq: true, unbound: false }) }, (ubus) => {
			assert.match([ 'enabled', 'disabled', 'not installed' ],
				map([ 'dnsmasq', 'unbound', 'dawn' ], (n) => services.state(ubus, n).data));
		});
	});

	it('reads rc as 25.12\'s rpcd answers, with stop and running or without', () => {
		with_ubus({ data: { 'rc:list': { odhcpd: { start: 35, stop: 85, enabled: true, running: false } } } }, (ubus) => {
			assert.match('enabled', services.state(ubus, 'odhcpd').data);
		});
	});

	it('fails when rc cannot be asked, or answers what it never does', () => {
		with_ubus({ errors: { 'rc:list': "Not found: Failed to resolve object name 'rc'" } }, (ubus) => {
			assert.match('UBUS_CALL_FAILED', services.state(ubus, 'dnsmasq').error);
		});
		with_ubus({ data: { 'rc:list': [ 1 ] } }, (ubus) => {
			assert.match('SOURCE_INVALID (rc list: not an object)', Result.describe(services.state(ubus, 'dnsmasq')));
		});
		with_ubus({ data: { 'rc:list': { dnsmasq: { start: 19 } } } }, (ubus) => {
			assert.match('SOURCE_INVALID (rc list: dnsmasq: no enabled)', Result.describe(services.state(ubus, 'dnsmasq')));
		});
	});
});

describe('services.unless_disabled', () => {
	let down = Result.err('UBUS_CALL_FAILED', 'dnsmasq metrics: Not found', { status: 'Not found' });

	it('is nothing to observe for a disabled service, or one not installed', () => {
		with_ubus({ data: rc({ dnsmasq: false }) }, (ubus) => {
			let a = services.unless_disabled(ubus, 'dnsmasq', down);
			let b = services.unless_disabled(ubus, 'dawn', down);

			assert.match([ true, 'dnsmasq is disabled', true, 'dawn is not installed' ],
				[ Result.is_none(a), a.none, Result.is_none(b), b.none ]);
		});
	});

	it('is the failure for an enabled service, and when rc cannot say', () => {
		with_ubus({ data: rc({ dnsmasq: true }) }, (ubus) => {
			assert.match(down, services.unless_disabled(ubus, 'dnsmasq', down));
		});
		with_ubus({ errors: { 'rc:list': 'Permission denied' } }, (ubus) => {
			assert.match(down, services.unless_disabled(ubus, 'dnsmasq', down));
		});
	});

	prop('is nothing to observe exactly when the script is not enabled',
		gen.tuple(gen.elements('enabled', 'disabled', 'absent'), gen.string({ charset: 'abcdefgh', min_len: 1, max_len: 8 })), (p) => {
			let scripts = (p[0] == 'absent') ? {} : { [p[1]]: p[0] == 'enabled' };

			with_ubus({ data: rc(scripts) }, (ubus) => {
				let r = services.unless_disabled(ubus, p[1], down);

				assert.match(p[0] != 'enabled', Result.is_none(r));
				assert.match(p[0] == 'enabled' ? null : `${p[1]} is ${p[0] == 'absent' ? 'not installed' : 'disabled'}`, services.idle(ubus, p[1]));
			});
		});
});

describe('services.object_missing', () => {
	it('tells an object that is not there from any other failure', () => {
		with_ubus({ errors: {
			'dsl:metrics': "Not found: Failed to resolve object name 'dsl'",
			'dhcp:nosuch': "Method not found: Failed to invoke function 'nosuch' on object 'dhcp'",
			'poe:info': 'Request timed out',
		}, data: { 'system:board': {} } }, (ubus) => {
			assert.match([ true, false, false, false ], map([ [ 'dsl', 'metrics' ], [ 'dhcp', 'nosuch' ], [ 'poe', 'info' ], [ 'system', 'board' ] ],
				(c) => services.object_missing(ubus.call(c[0], c[1]))));
		});
		assert.match([ false, false ], [
			services.object_missing(Result.err('UBUS_CONNECT_FAILED')),
			services.object_missing(Result.err('SOURCE_INVALID', 'x', { status: 'Not found' })),
		]);
	});
});
