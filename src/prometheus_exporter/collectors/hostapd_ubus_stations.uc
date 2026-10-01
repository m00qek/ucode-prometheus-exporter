'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hostapd_ubus_stations.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hostapd_ubus_stations collector: the radio resource
// measurement (802.11k) capabilities each client of every hostapd.* ubus object
// announced, as get_clients' `rrm` array holds them (the five octets of the RRM
// Enabled Capabilities element), labelled {ifname, freq, station}.
//
// A client without that array is left out, where Lua stopped with an error. A
// hostapd object without get_clients (a wired 802.1X port) is skipped; any
// other failed call leaves its interface out, and fails the collector once the
// others are written.

import * as Result from 'prometheus_exporter.result';

export const meta = {
	name: 'hostapd_ubus_stations',
	title: 'hostapd station capabilities',
	help: 'Radio measurement capabilities of hostapd\'s stations, from hostapd\'s ubus objects.',
	needs: [ 'ubus' ],
};

// [ family, help, octet, bit ] per capability, in Lua's order.
const CAPABILITIES = [
	[ 'link_measurement', 'link measurement', 0, 0 ],
	[ 'neighbor_report', 'neighbor report', 0, 1 ],
	[ 'beacon_report_passive', 'passive beacon report', 0, 4 ],
	[ 'beacon_report_active', 'active beacon report', 0, 5 ],
	[ 'beacon_report_table', 'beacon table report', 0, 6 ],
	[ 'lci_measurement', 'LCI measurement', 1, 4 ],
	[ 'ftm_range_report', 'FTM range report', 4, 2 ],
];

function station(families, labels, rrm) {
	for (let i, cap in CAPABILITIES) {
		let octet = rrm[cap[2]];

		families[i](labels, type(octet) == 'int' && (octet & (1 << cap[3])) != 0);
	}
}

// One object's samples; null, or the Result of a failed call.
function access_point(ubus, families, object) {
	let res = ubus.call(object, 'get_clients');

	if (!res.ok)
		return match(res.details ?? '', /: Method not found/) ? null : res;

	let ifname = substr(object, length('hostapd.'));

	for (let mac, c in res.data?.clients ?? {}) {
		if (type(c?.rrm) == 'array')
			station(families, { ifname, freq: res.data.freq, station: mac }, c.rrm);
	}

	return null;
}

export function collect(deps, out) {
	let res = deps.ubus.list();

	if (!res.ok)
		return res;

	let families = map(CAPABILITIES, (cap) => out.gauge(`hostapd_ubus_station_rrm_caps_${cap[0]}`,
		`Whether the station supports ${cap[1]}.`));
	let failure = null;

	for (let object in sort(filter(res.data ?? [], (name) => match(name, /^hostapd\./)))) {
		let fail = access_point(deps.ubus, families, object);
		failure ??= fail;
	}

	return failure ?? Result.ok();
};
