'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/dnsmasq.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'dnsmasq',
	help: 'DNS and DHCP counters of dnsmasq, from ubus dnsmasq metrics.',
	needs: [ 'ubus' ],
};

// Every metric dnsmasq reports, as dnsmasq_<key>_total. They stay gauges, as in
// the ucode exporter this replaces: most are counters, but the dnssec_max_* ones
// are high-water marks, and the list grows with dnsmasq releases, so no fixed
// list could type each one.
export function collect(deps, out) {
	let res = deps.ubus.call('dnsmasq', 'metrics');

	if (!res.ok)
		return res;
	if (type(res.data) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'dnsmasq metrics: not an object');

	for (let key, value in res.data)
		out.gauge(`dnsmasq_${key}_total`, `dnsmasq's ${key} metric.`)(null, value);

	return Result.ok();
};
