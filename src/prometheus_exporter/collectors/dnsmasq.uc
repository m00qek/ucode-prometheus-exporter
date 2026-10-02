'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/dnsmasq.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, services } from 'prometheus_exporter.api';

export const meta = {
	name: 'dnsmasq',
	title: 'dnsmasq DNS and DHCP',
	help: 'DNS and DHCP counters of dnsmasq, from ubus dnsmasq metrics.',
	needs: [ 'ubus' ],
};

// What dnsmasq's metrics are (src/metrics.c and its uses): the high-water marks
// of DNSSEC work and the TCP connections open now are gauges, dnsmasq_<key>;
// every other metric dnsmasq 2.91 has counts up from its start (or from a
// SIGUSR1 that clears them, which Prometheus takes as a counter reset) and is
// a counter, dnsmasq_<key>_total. A key a later dnsmasq adds is not known to be
// either: it is untyped, dnsmasq_<key>.
//
// google/dnsmasq_exporter's names (dnsmasq_hits, dnsmasq_misses, ...) are not
// followed: they are counters without _total, typed as gauges, and come from
// the CHAOS TXT records, which are other figures.
export const GAUGES = [ 'dnssec_max_crypto_use', 'dnssec_max_sig_fail', 'dnssec_max_work', 'tcp_connections' ];
export const COUNTERS = [
	'dns_cache_inserted', 'dns_cache_live_freed', 'dns_queries_forwarded', 'dns_auth_answered',
	'dns_local_answered', 'dns_stale_answered', 'dns_unanswered', 'bootp', 'pxe', 'dhcp_ack',
	'dhcp_decline', 'dhcp_discover', 'dhcp_inform', 'dhcp_nak', 'dhcp_offer', 'dhcp_release',
	'dhcp_request', 'noanswer', 'leases_allocated_4', 'leases_pruned_4', 'leases_allocated_6',
	'leases_pruned_6', 'dhcp_leasequery', 'dhcp_lease_unassigned', 'dhcp_lease_actve', 'dhcp_lease_unknown',
];

// [ type, name ] of a key's family.
export function family_of(key) {
	if (key in COUNTERS)
		return [ 'counter', `dnsmasq_${key}_total` ];

	return [ key in GAUGES ? 'gauge' : 'untyped', `dnsmasq_${key}` ];
};

// dnsmasq disabled (its init script), or not installed, is nothing to
// observe; enabled and not answering, a failure.
export function collect(deps, out) {
	let res = deps.ubus.call('dnsmasq', 'metrics');

	if (!res.ok)
		return services.unless_disabled(deps.ubus, 'dnsmasq', res);
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'dnsmasq metrics: not an object');

	for (let key, value in res.data) {
		let f = family_of(key);
		out[f[0]](f[1], `dnsmasq's ${key} metric.`)(null, value);
	}

	return Result.ok();
};
