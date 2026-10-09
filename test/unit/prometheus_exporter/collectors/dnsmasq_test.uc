'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus_exporter.devkit.collector';
import { rc } from 'prometheus_exporter.devkit.rc';
import * as fixtures from 'lib.fixtures';
import * as dnsmasq from 'prometheus_exporter.collectors.dnsmasq';

const ROUTER = fixtures.ubus('caju-router', 'dnsmasq', 'metrics');

describe('collectors.dnsmasq', () => {
	it('exports every metric of the caju router dnsmasq: the counters with _total, the gauges without', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': ROUTER } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(3 * length(ROUTER), length(r.lines));
			assert.match([
				'# HELP dnsmasq_dns_cache_inserted_total dnsmasq\'s dns_cache_inserted metric.',
				'# TYPE dnsmasq_dns_cache_inserted_total counter',
				'dnsmasq_dns_cache_inserted_total 0',
				'# HELP dnsmasq_dns_cache_live_freed_total dnsmasq\'s dns_cache_live_freed metric.',
				'# TYPE dnsmasq_dns_cache_live_freed_total counter',
				'dnsmasq_dns_cache_live_freed_total 0',
				'# HELP dnsmasq_dns_queries_forwarded_total dnsmasq\'s dns_queries_forwarded metric.',
				'# TYPE dnsmasq_dns_queries_forwarded_total counter',
				'dnsmasq_dns_queries_forwarded_total 2',
			], slice(r.lines, 0, 9));
			assert.match(contains([
				'dnsmasq_dns_local_answered_total 170',
				'dnsmasq_dhcp_ack_total 27',
				'dnsmasq_dhcp_discover_total 8',
				'dnsmasq_leases_allocated_4_total 9',
				// dnsmasq's own spelling.
				'dnsmasq_dhcp_lease_actve_total 0',
			]), r.lines);
			assert.match(contains([
				'# TYPE dnsmasq_dnssec_max_crypto_use gauge',
				'dnsmasq_dnssec_max_crypto_use 0',
				'# TYPE dnsmasq_tcp_connections gauge',
				'dnsmasq_tcp_connections 0',
			]), r.lines);
			assert.match([ 'counter', 'gauge' ], sort(uniq(map(r.families, (f) => f.type))));
		});
	});

	it('passes on the ubus error when dnsmasq is enabled and not running', () => {
		with_collector(dnsmasq, { ubus: { data: rc({ dnsmasq: true }), errors: { 'dnsmasq:metrics': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'dnsmasq metrics: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('has nothing to observe where dnsmasq is disabled', () => {
		with_collector(dnsmasq, { ubus: { data: rc({ dnsmasq: false }), errors: { 'dnsmasq:metrics': 'Not found' } } }, (r) => {
			assert.match({ ok: true, none: 'dnsmasq is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('passes on the ubus error when rc cannot say', () => {
		with_collector(dnsmasq, { ubus: { errors: { 'dnsmasq:metrics': 'Not found', 'rc:list': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
		});
	});

	it('reads a running dnsmasq, and asks rc nothing', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': { bootp: 1 } } } }, (r) => {
			assert.match([ true, null, [ 'dnsmasq_bootp_total 1' ] ], [ r.result.ok, r.result.none, filter(r.lines, (l) => substr(l, 0, 1) != '#') ]);
		});
	});

	it('fails with SOURCE_INVALID for a reply that is not an object', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': [ 1, 2 ] } } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	it('skips a value that is not a number', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': { bootp: 1, version: 'x' } } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'dnsmasq_bootp_total 1' ], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	// dnsmasq sends every metric with blobmsg_add_u32(), which ucode's ubus gives signed.
	it('reads a count past 2^31 unsigned, as dnsmasq sent it', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': { dns_queries_forwarded: -2147483000, bootp: -1 } } } }, (r) => {
			assert.match([ 'dnsmasq_dns_queries_forwarded_total 2147484296', 'dnsmasq_bootp_total 4294967295' ],
				filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('exports a metric it does not know as untyped, without _total', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': { dns_new_thing: 3 } } } }, (r) => {
			assert.match([ "# HELP dnsmasq_dns_new_thing dnsmasq's dns_new_thing metric.", '# TYPE dnsmasq_dns_new_thing untyped',
				'dnsmasq_dns_new_thing 3' ], r.lines);
		});
	});

	prop('exports one sample per key, with its value, named by what the key is',
		gen.array(gen.tuple(gen.string({ charset: 'abcdefgh_', min_len: 1, max_len: 12 }), gen.int(0, 1000000)), { max_len: 8 }),
		(pairs) => {
			let reply = {};
			for (let p in pairs)
				reply[p[0]] = p[1];

			with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': reply } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(reply), (k) => `${dnsmasq.family_of(k)[1]} ${reply[k]}`)),
					sort(filter(r.lines, (l) => substr(l, 0, 1) != '#')));
			});
		});

	prop('names every known counter with _total and nothing else',
		gen.oneof(gen.elements(...dnsmasq.COUNTERS), gen.elements(...dnsmasq.GAUGES), gen.string({ charset: 'abcdefgh_', min_len: 1, max_len: 12 })),
		(key) => {
			let f = dnsmasq.family_of(key);

			assert.match(key in dnsmasq.COUNTERS, f[0] == 'counter');
			assert.match(f[0] == 'counter', substr(f[1], -6) == '_total');
			assert.match(key in dnsmasq.GAUGES, f[0] == 'gauge');
		});
});
