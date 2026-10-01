'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/dawn.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's dawn collector: the access points this node serves in the
// network overview of DAWN, the decentralized Wi-Fi controller (ubus dawn
// get_network), and the signal of their clients. get_network nests
// { ssid: { bssid: { ap fields..., client mac: { client fields } } } }, the
// only objects under an AP being its clients; APs of other nodes are left out.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const meta = {
	name: 'dawn',
	title: 'DAWN band steering',
	help: 'Access points and client signal from the DAWN Wi-Fi controller.',
	needs: [ 'ubus' ],
};

function bit(v) {
	return v === true ? 1 : 0;
}

function access_point(m, ssid, bssid, ap) {
	let labels = {
		ssid,
		bssid,
		freq: ap.freq,
		hostname: ap.hostname,
		ht_support: bit(ap.ht_support),
		vht_support: bit(ap.vht_support),
		neighbor_report: ap.neighbor_report,
	};

	if (type(ap.channel_utilization) in [ 'int', 'double' ])
		m.utilization(labels, ap.channel_utilization / 255.0);
	m.stations(labels, ap.num_sta);

	for (let mac, client in ap) {
		if (type(client) != 'object')
			continue;

		m.signal({
			ssid,
			bssid,
			mac,
			ht_support: bit(client.ht),
			vht_support: bit(client.vht),
		}, client.signal ?? -255);
	}
}

export function collect(deps, out) {
	let res = deps.ubus.call('dawn', 'get_network');

	if (!res.ok)
		return res;

	let network = res.data;
	if (type(network) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'dawn get_network: not an object');

	let m = {
		utilization: out.gauge('dawn_ap_channel_utilization_ratio', 'Channel utilization of the access point, from 0 to 1.'),
		stations: out.gauge('dawn_ap_stations', 'Stations associated with the access point.'),
		signal: out.gauge('dawn_station_signal_dbm', 'Signal of the station, in dBm; -255 when DAWN has not heard it.'),
	};

	for (let ssid, aps in network) {
		for (let bssid, ap in (type(aps) == 'object' ? aps : {})) {
			if (type(ap) == 'object' && ap.local === true)
				access_point(m, ssid, bssid, ap);
		}
	}

	return Result.ok();
};
