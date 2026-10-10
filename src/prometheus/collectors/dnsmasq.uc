'use strict';

import { Result, errors, services, u32 } from 'prometheus.exporter';

export const meta = {
	name: 'dnsmasq',
	title: 'dnsmasq DNS and DHCP',
	help: 'DNS and DHCP counters of dnsmasq, from ubus dnsmasq metrics.',
	needs: [ 'ubus' ],
	ubus: { dnsmasq: [ 'metrics' ], rc: [ 'list' ] },
};

export const GAUGES = [ 'dnssec_max_crypto_use', 'dnssec_max_sig_fail', 'dnssec_max_work', 'tcp_connections' ];
export const COUNTERS = [
	'dns_cache_inserted', 'dns_cache_live_freed', 'dns_queries_forwarded', 'dns_auth_answered',
	'dns_local_answered', 'dns_stale_answered', 'dns_unanswered', 'bootp', 'pxe', 'dhcp_ack',
	'dhcp_decline', 'dhcp_discover', 'dhcp_inform', 'dhcp_nak', 'dhcp_offer', 'dhcp_release',
	'dhcp_request', 'noanswer', 'leases_allocated_4', 'leases_pruned_4', 'leases_allocated_6',
	'leases_pruned_6', 'dhcp_leasequery', 'dhcp_lease_unassigned', 'dhcp_lease_actve', 'dhcp_lease_unknown',
];

export function family_of(key) {
	if (key in COUNTERS)
		return [ 'counter', `dnsmasq_${key}_total` ];

	return [ key in GAUGES ? 'gauge' : 'untyped', `dnsmasq_${key}` ];
};

export function collect(deps, out) {
	let res = deps.ubus.call('dnsmasq', 'metrics');

	if (!res.ok)
		return services.unless_disabled(deps.ubus, 'dnsmasq', res);
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'dnsmasq metrics: not an object');

	for (let key, value in res.data) {
		let f = family_of(key);
		out[f[0]](f[1], `dnsmasq's ${key} metric.`)(null, u32(value));
	}

	return Result.ok();
};
