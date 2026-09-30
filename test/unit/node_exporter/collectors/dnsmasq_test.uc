'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as dnsmasq from 'node_exporter.collectors.dnsmasq';

const ROUTER = fixtures.ubus('caju-router', 'dnsmasq', 'metrics');

describe('collectors.dnsmasq', () => {
	it('exports every metric of the caju router dnsmasq as a dnsmasq_<key>_total gauge', () => {
		with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': ROUTER } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(3 * length(ROUTER), length(r.lines));
			assert.match([
				'# HELP dnsmasq_dns_cache_inserted_total dnsmasq\'s dns_cache_inserted metric.',
				'# TYPE dnsmasq_dns_cache_inserted_total gauge',
				'dnsmasq_dns_cache_inserted_total 0',
				'# HELP dnsmasq_dns_cache_live_freed_total dnsmasq\'s dns_cache_live_freed metric.',
				'# TYPE dnsmasq_dns_cache_live_freed_total gauge',
				'dnsmasq_dns_cache_live_freed_total 0',
				'# HELP dnsmasq_dns_queries_forwarded_total dnsmasq\'s dns_queries_forwarded metric.',
				'# TYPE dnsmasq_dns_queries_forwarded_total gauge',
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
		});
	});

	it('passes on the ubus error when dnsmasq is not running', () => {
		with_collector(dnsmasq, { ubus: { errors: { 'dnsmasq:metrics': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'dnsmasq metrics: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
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

	prop('exports one sample per key, with its value',
		gen.array(gen.tuple(gen.string({ charset: 'abcdefgh_', min_len: 1, max_len: 12 }), gen.int(0, 1000000)), { max_len: 8 }),
		(pairs) => {
			let reply = {};
			for (let p in pairs)
				reply[p[0]] = p[1];

			with_collector(dnsmasq, { ubus: { data: { 'dnsmasq:metrics': reply } } }, (r) => {
				assert.match(true, r.result.ok);
				assert.match(sort(map(keys(reply), (k) => `dnsmasq_${k}_total ${reply[k]}`)),
					sort(filter(r.lines, (l) => substr(l, 0, 1) != '#')));
			});
		});
});
