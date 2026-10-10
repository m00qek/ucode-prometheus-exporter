'use strict';

import { describe, it, prop, gen, assert, mock } from 'utest';
import * as deps_ubus from 'prometheus.exporter.deps.ubus';

function brief(res) {
	return res.ok ? { ok: true, data: res.data } : { ok: false, error: res.error, details: res.details };
}

describe('deps.ubus.ubus_channel', () => {
	it('connects on the first call only', () => {
		mock.inject('ubus', { strict: true, data: { 'system:board': { model: 'm' } } }, (ubus) => {
			let connects = 0;
			let ch = deps_ubus.ubus_channel(() => { connects++; return ubus.connect(); });

			assert.match(0, connects);
			assert.match({ ok: true, data: { model: 'm' } }, brief(ch.call('system', 'board')));
			ch.call('system', 'board');
			assert.match(1, connects);
		});
	});

	// A connection's timeout, in ucode's ubus, is set when it connects.
	it('waits no longer than the collector\'s limit: a connection of the seconds left, a second at least', () => {
		mock.inject('ubus', { strict: true, data: { 'system:board': {} } }, (ubus) => {
			let now = 100;
			let timeouts = [];
			let ch = deps_ubus.ubus_channel(function(path, timeout) { push(timeouts, timeout); return ubus.connect(); }, () => [ now, 0 ]);

			ch.call('system', 'board');
			ch.limit(104.2);
			ch.call('system', 'board');
			now = 102;
			ch.call('system', 'board');
			now = 104.1;
			ch.call('system', 'board');
			ch.limit(110);
			ch.call('system', 'board');
			ch.limit(null);
			ch.call('system', 'board');

			assert.match([ deps_ubus.UBUS_TIMEOUT, 5, 3, 1, 6, deps_ubus.UBUS_TIMEOUT ], timeouts);
		});
	});

	prop('never connects for longer than is left before the limit, nor for less than a second',
		gen.tuple(gen.int(0, 100), gen.int(0, 100)), (t) => {
			mock.inject('ubus', { strict: true, data: { 'a:b': {} } }, (ubus) => {
				let got = [];
				let ch = deps_ubus.ubus_channel(function(path, timeout) { push(got, timeout); return ubus.connect(); }, () => [ t[0], 0 ]);

				ch.limit(t[0] + t[1] / 10.0);
				ch.call('a', 'b');
				assert.match(true, got[0] >= 1 && got[0] <= max(1, int(t[1] / 10.0 + 0.999)), got);
			});
		});

	it('tells a method without data from a failed call', () => {
		mock.inject('ubus', { strict: true, data: { 'svc:quiet': null }, errors: { 'svc:broken': 'Not found' } }, (ubus) => {
			let ch = deps_ubus.ubus_channel(ubus.connect);

			assert.match({ ok: true, data: null }, brief(ch.call('svc', 'quiet')));
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'svc broken: Not found' }, brief(ch.call('svc', 'broken')));
		});
	});

	it('gives a failed call the status error() puts first, as 25.12\'s ucode words it', () => {
		mock.inject('ubus', { strict: true, errors: {
			'dsl:metrics': "Not found: Failed to resolve object name 'dsl'",
			'dhcp:nosuch': "Method not found: Failed to invoke function 'nosuch' on object 'dhcp'",
			'svc:bare': 'Request timed out',
		} }, (ubus) => {
			let ch = deps_ubus.ubus_channel(ubus.connect);
			let dsl = ch.call('dsl', 'metrics');

			assert.match("dsl metrics: Not found: Failed to resolve object name 'dsl'", dsl.details);
			assert.match([ { status: 'Not found' }, { status: 'Method not found' }, { status: 'Request timed out' } ],
				[ dsl.data, ch.call('dhcp', 'nosuch').data, ch.call('svc', 'bare').data ]);
		});
	});

	prop('takes the status from the text before the first ": ", or all of a text without one',
		gen.tuple(gen.string({ charset: 'abc d', min_len: 1, max_len: 10 }), gen.ascii({ max_len: 20 })), (p) => {
			assert.match(p[0], deps_ubus.ubus_status(`${p[0]}: ${p[1]}`));
			assert.match(p[0], deps_ubus.ubus_status(p[0]));
		});

	it('fails every call when ubusd cannot be reached', () => {
		let ch = deps_ubus.ubus_channel(() => null);

		assert.match([ 'UBUS_CONNECT_FAILED', 'UBUS_CONNECT_FAILED' ], [ ch.call('a', 'b').error, ch.list().error ]);
	});

	it('lists the published objects', () => {
		mock.inject('ubus', { strict: true, data: { 'hostapd.phy0-ap0:get_clients': {}, 'system:board': {}, 'system:info': {} } }, (ubus) => {
			assert.match([ 'hostapd.phy0-ap0', 'system' ], deps_ubus.ubus_channel(ubus.connect).list().data);
		});
	});

	it('disconnects on close and connects again after', () => {
		mock.inject('ubus', { strict: true, data: { 'a:b': 1 } }, (ubus) => {
			let conns = [];
			let ch = deps_ubus.ubus_channel(() => { let c = ubus.connect(); push(conns, c); return c; });

			ch.call('a', 'b');
			ch.close();
			ch.call('a', 'b');
			assert.match([ 1, 0 ], map(conns, (c) => length(c.__utest__.calls.disconnect)));
		});
	});

	// ubusd holds the service's user to its ACL: DENIED for a method it may not
	// call, NOT_FOUND for an object it may call nothing of, as for one that is
	// not there; the canary tells the two apart.
	it('fails a call ubusd denies with PERMISSION_DENIED, never as a failed call', () => {
		mock.inject('ubus', { strict: true, data: {}, errors: { 'system:info': 'Permission denied' } }, (ubus) => {
			assert.match({ ok: false, error: 'PERMISSION_DENIED', details: "system info: Permission denied: the service's ubus ACL does not allow it" },
				brief(deps_ubus.ubus_channel(ubus.connect).call('system', 'info')));
		});
	});

	it('fails a call to an object not there with PERMISSION_DENIED while ubusd has not loaded the ACL, and as a failed call while it has', () => {
		let cfg = (loaded) => ({ strict: true, data: {}, errors: { 'dsl:metrics': 'Not found', ...(loaded ? {} : { 'list:system': 'Not found' }) } });

		mock.inject('ubus', cfg(false), (ubus) => {
			assert.match({ ok: false, error: 'PERMISSION_DENIED', details: "dsl metrics: Not found: ubusd has not loaded the service's ACL (/usr/share/acl.d/prometheus-exporter.json)" },
				brief(deps_ubus.ubus_channel(ubus.connect).call('dsl', 'metrics')));
		});
		mock.inject('ubus', cfg(true), (ubus) => {
			let res = deps_ubus.ubus_channel(ubus.connect).call('dsl', 'metrics');

			assert.match([ 'UBUS_CALL_FAILED', 'dsl metrics: Not found', 'Not found' ], [ res.error, res.details, res.data.status ]);
		});
	});

	it('looks for the canary once a connection, and only once a call finds no object', () => {
		mock.inject('ubus', { strict: true, data: { 'a:b': 1 }, errors: { 'dsl:metrics': 'Not found' } }, (ubus) => {
			let conns = [];
			let ch = deps_ubus.ubus_channel(() => { let c = ubus.connect(); push(conns, c); return c; });

			ch.call('a', 'b');
			assert.match([], conns[0].__utest__.calls.list);
			ch.call('dsl', 'metrics');
			ch.call('dsl', 'metrics');
			assert.match([ [ 'system' ] ], conns[0].__utest__.calls.list);
			ch.close();
			ch.call('dsl', 'metrics');
			assert.match([ [ 'system' ] ], conns[1].__utest__.calls.list);
		});
	});
});

describe('deps.ubus.ubus_for', () => {
	it('calls what the collector declares, an object of a prefix too', () => {
		mock.inject('ubus', { strict: true, data: { 'dnsmasq:metrics': { a: 1 }, 'hostapd.wlan0:get_clients': { b: 2 } } }, (ubus) => {
			let ch = deps_ubus.ubus_for(deps_ubus.ubus_channel(ubus.connect), { dnsmasq: [ 'metrics' ], 'hostapd.*': [ 'get_clients' ] });

			assert.match([ { ok: true, data: { a: 1 } }, { ok: true, data: { b: 2 } } ],
				[ brief(ch.call('dnsmasq', 'metrics')), brief(ch.call('hostapd.wlan0', 'get_clients')) ]);
		});
	});

	it('refuses, without calling it, what the collector does not declare', () => {
		mock.inject('ubus', { strict: true, data: { 'dnsmasq:metrics': {} } }, (ubus) => {
			let conns = [];
			let ch = deps_ubus.ubus_for(deps_ubus.ubus_channel(() => { let c = ubus.connect(); push(conns, c); return c; }), { rc: [ 'list' ] });

			assert.match({ ok: false, error: 'UBUS_NOT_ALLOWED', details: 'dnsmasq metrics: not in meta.ubus' }, brief(ch.call('dnsmasq', 'metrics')));
			assert.match({ ok: false, error: 'UBUS_NOT_ALLOWED', details: 'rc init: not in meta.ubus' }, brief(ch.call('rc', 'init', { name: 'x' })));
			assert.match(0, length(conns));
		});
	});

	it('lists the objects as the channel does', () => {
		mock.inject('ubus', { strict: true, data: { 'system:board': {} } }, (ubus) => {
			assert.match([ 'system' ], deps_ubus.ubus_for(deps_ubus.ubus_channel(ubus.connect), {}).list().data);
		});
	});
});
