'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/wifi_stations.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

// The Lua exporter's wifi_stations collector: the stations of each interface in
// ubus network.wireless status, with its families and {ifname, mac} labels. Lua
// read them through iwinfo; this reads the nl80211 station dump iwinfo makes,
// so the values are the same: rates in kbit/s, and signal, expected throughput
// and rates left out when the driver reports 0.
//
// The wifi collector's `stations` option writes the same wifi_station_*
// families, with a `radio` label besides. Install one of the two, or set that
// option off, or each station is exported twice.
//
// An interface whose dump fails is left out, and fails the collector once the
// others are written.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'wifi_stations',
	help: 'Wi-Fi stations of each interface, from ubus network.wireless and nl80211.',
	needs: [ 'ubus', 'nl80211' ],
};

function metrics(out) {
	return {
		stations: out.gauge('wifi_stations', 'Stations associated with the interface.'),
		signal: out.gauge('wifi_station_signal_dbm', 'Signal of the station, in dBm.'),
		inactive: out.gauge('wifi_station_inactive_milliseconds', 'Time since the station was last active, in milliseconds.'),
		expected_throughput: out.gauge('wifi_station_expected_throughput_kilobits_per_second', 'Expected throughput to the station, in kbit/s.'),
		tx_bitrate: out.gauge('wifi_station_transmit_kilobits_per_second', 'Bitrate of the last packet transmitted to the station, in kbit/s.'),
		rx_bitrate: out.gauge('wifi_station_receive_kilobits_per_second', 'Bitrate of the last packet received from the station, in kbit/s.'),
		tx_packets: out.counter('wifi_station_transmit_packets_total', 'Packets transmitted to the station.'),
		rx_packets: out.counter('wifi_station_receive_packets_total', 'Packets received from the station.'),
		tx_bytes: out.counter('wifi_station_transmit_bytes_total', 'Bytes transmitted to the station.'),
		rx_bytes: out.counter('wifi_station_receive_bytes_total', 'Bytes received from the station.'),
	};
}

function station(m, ifname, sta) {
	let labels = { ifname, mac: sta?.mac };
	let info = sta?.sta_info ?? {};

	if (info.signal)
		m.signal(labels, info.signal);
	m.inactive(labels, info.inactive_time);
	if (info.expected_throughput)
		m.expected_throughput(labels, info.expected_throughput);
	if (info.tx_bitrate?.bitrate32)
		m.tx_bitrate(labels, info.tx_bitrate.bitrate32 * 100);
	if (info.rx_bitrate?.bitrate32)
		m.rx_bitrate(labels, info.rx_bitrate.bitrate32 * 100);
	m.tx_packets(labels, info.tx_packets);
	m.rx_packets(labels, info.rx_packets);
	m.tx_bytes(labels, info.tx_bytes64 ?? info.tx_bytes);
	m.rx_bytes(labels, info.rx_bytes64 ?? info.rx_bytes);
}

// One interface's samples; null, or the Result of a failed dump.
function interface_stations(nl, m, ifname) {
	let res = nl.request(nl.const.NL80211_CMD_GET_STATION, nl.const.NLM_F_DUMP, { dev: ifname });

	if (!res.ok)
		return Result.err(res.error, `${ifname}: ${res.details}`);

	// An empty dump is a null reply.
	let stations = type(res.data) == 'array' ? res.data : [];

	for (let sta in stations)
		station(m, ifname, sta);

	m.stations({ ifname }, length(stations));
	return null;
}

export function collect(deps, out) {
	let res = deps.ubus.call('network.wireless', 'status');

	if (!res.ok)
		return res;

	let status = res.data;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'network.wireless status: not an object');

	let m = metrics(out);
	let failure = null;

	for (let radio, r in status) {
		for (let iface in r?.interfaces ?? []) {
			if (type(iface?.ifname) != 'string')
				continue;

			let fail = interface_stations(deps.nl80211, m, iface.ifname);
			failure ??= fail;
		}
	}

	return failure ?? Result.ok();
};
