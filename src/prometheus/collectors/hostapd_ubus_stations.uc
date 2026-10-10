'use strict';

import { Result } from 'prometheus.exporter';

export const meta = {
	name: 'hostapd_ubus_stations',
	title: 'hostapd station capabilities',
	help: 'Radio measurement capabilities of hostapd\'s stations, from hostapd\'s ubus objects.',
	needs: [ 'ubus' ],
	ubus: { 'hostapd.*': [ 'get_clients' ] },
};

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

function access_point(ubus, out, families, object) {
	let res = ubus.call(object, 'get_clients');

	if (!res.ok)
		return index(res.details ?? '', ': Method not found') >= 0 ? null : res;

	let ifname = substr(object, length('hostapd.'));

	for (let mac, c in res.data?.clients ?? {}) {
		if (type(c?.rrm) == 'array')
			station(families, out.labels({ ifname, freq: res.data.freq, station: mac }), c.rrm);
	}

	return null;
}

export function collect(deps, out) {
	let res = deps.ubus.list();

	if (!res.ok)
		return res;

	let objects = sort(filter(res.data ?? [], (name) => substr(name, 0, 8) == 'hostapd.'));
	if (!length(objects))
		return Result.none('no hostapd access points');

	let families = map(CAPABILITIES, (cap) => out.gauge(`hostapd_ubus_station_rrm_caps_${cap[0]}`,
		`Whether the station supports ${cap[1]}.`));
	let failure = null;

	for (let object in objects) {
		let fail = access_point(deps.ubus, out, families, object);
		failure ??= fail;
	}

	return failure ?? Result.ok();
};
