'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/wifi.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The upstream ucode exporter's wifi collector: each radio and network in ubus
// network.wireless status, with what nl80211 knows of the network's interface,
// stations and channel. Families, labels and values are upstream's, NaN for a
// network without stations included.
//
// With option `stations` (on by default) it also writes one sample per station
// to the wifi_station_* families, which the wifi_stations collector writes too
// (without the `radio` label). Install one of the two, or set `stations` off
// here, or each station is exported twice.
//
// An interface nl80211 cannot answer for is left out and fails the collector
// once the other interfaces are written. A driver without a channel survey
// gives no noise reading: NaN, as upstream, and not a failure.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'wifi',
	help: 'Wi-Fi radios, networks and stations, from ubus network.wireless and nl80211.',
	needs: [ 'ubus', 'nl80211' ],
	options: { stations: true },
};

// The mode of an interface by its NL80211_IFTYPE_* value.
const IFTYPES = [
	'Unknown', 'Ad-Hoc', 'Client', 'Master', 'Master (VLAN)', 'WDS', 'Monitor',
	'Mesh Point', 'P2P Client', 'P2P Go', 'P2P Device', 'OCB',
];

function metrics(out) {
	return {
		radio_info: out.gauge('wifi_radio_info', 'A Wi-Fi radio, by its mode, channel and country.'),
		network_info: out.gauge('wifi_network_info', 'A Wi-Fi network, by its SSID, BSSID and mode.'),
		network_quality: out.gauge('wifi_network_quality', 'Signal quality of the network\'s stations, in percent.'),
		network_bitrate: out.gauge('wifi_network_bitrate', 'Average transmit bitrate to the network\'s stations, in kbit/s.'),
		network_noise: out.gauge('wifi_network_noise_dbm', 'Noise on the network\'s channel, in dBm.'),
		network_signal: out.gauge('wifi_network_signal_dbm', 'Average signal of the network\'s stations, in dBm.'),
		stations_total: out.counter('wifi_stations_total', 'Stations associated with the network.'),
		inactive: out.gauge('wifi_station_inactive_milliseconds', 'Time since the station was last active, in milliseconds.'),
		rx_bytes: out.counter('wifi_station_receive_bytes_total', 'Bytes received from the station.'),
		tx_bytes: out.counter('wifi_station_transmit_bytes_total', 'Bytes transmitted to the station.'),
		rx_packets: out.counter('wifi_station_receive_packets_total', 'Packets received from the station.'),
		tx_packets: out.counter('wifi_station_transmit_packets_total', 'Packets transmitted to the station.'),
		signal: out.gauge('wifi_station_signal_dbm', 'Signal of the station, in dBm.'),
		rx_bitrate: out.gauge('wifi_station_receive_kilobits_per_second', 'Bitrate of the last packet received from the station, in kbit/s.'),
		tx_bitrate: out.gauge('wifi_station_transmit_kilobits_per_second', 'Bitrate of the last packet transmitted to the station, in kbit/s.'),
		expected_throughput: out.gauge('wifi_station_expected_throughput_kilobits_per_second', 'Expected throughput to the station, in kbit/s.'),
	};
}

function failed(res, ifname) {
	return Result.err(res.error, `${ifname}: ${res.details}`);
}

// The mean of the values `pick` finds in `list`, or NaN for none (or a mean of
// 0, as upstream).
function mean(list, pick) {
	let sum = 0, n = 0;

	for (let x in list) {
		let v = pick(x);
		if (type(v) in [ 'int', 'double' ]) {
			sum += v;
			n++;
		}
	}

	return (n && sum) ? sum / (n * 1.0) : NaN;
}

function noise_at(survey, freq) {
	for (let s in (type(survey) == 'array' ? survey : [])) {
		if (s?.survey_info?.frequency == freq)
			return s.survey_info.noise || NaN;
	}

	return NaN;
}

function station(m, radio, ifname, sta) {
	let labels = { radio, ifname, mac: sta?.mac };
	let info = sta?.sta_info ?? {};

	m.inactive(labels, info.inactive_time);
	m.rx_bytes(labels, info.rx_bytes64 ?? info.rx_bytes);
	m.tx_bytes(labels, info.tx_bytes64 ?? info.tx_bytes);
	m.rx_packets(labels, info.rx_packets);
	m.tx_packets(labels, info.tx_packets);
	m.signal(labels, info.signal);
	if (info.rx_bitrate?.bitrate32)
		m.rx_bitrate(labels, info.rx_bitrate.bitrate32 * 100);
	if (info.tx_bitrate?.bitrate32)
		m.tx_bitrate(labels, info.tx_bitrate.bitrate32 * 100);
	if (info.expected_throughput)
		m.expected_throughput(labels, info.expected_throughput);
}

// One network's samples; null, or the Result of the request that failed.
function network(nl, m, radio, iface, with_stations) {
	let C = nl.const;
	let ifname = iface.ifname;
	let nc = iface.config ?? {};

	let res = nl.request(C.NL80211_CMD_GET_INTERFACE, 0, { dev: ifname });
	if (!res.ok)
		return failed(res, ifname);

	let wif = res.data;
	if (type(wif) != 'object')
		return null;

	m.network_info({
		radio,
		ifname,
		ssid: nc.ssid || nc.mesh_id,
		bssid: wif.mac,
		mode: IFTYPES[wif.iftype],
	}, 1);

	res = nl.request(C.NL80211_CMD_GET_STATION, C.NLM_F_DUMP, { dev: ifname });
	if (!res.ok)
		return failed(res, ifname);

	// An empty dump is a null reply.
	let stations = type(res.data) == 'array' ? res.data : [];
	let labels = { radio, ifname };
	let bitrate = mean(stations, (s) => s?.sta_info?.tx_bitrate?.bitrate32);
	let signal = mean(stations, (s) => s?.sta_info?.signal);

	m.network_bitrate(labels, bitrate * 100);
	m.network_signal(labels, signal);
	m.network_quality(labels, 100.0 / 70 * (signal + 110));

	res = nl.request(C.NL80211_CMD_GET_SURVEY, C.NLM_F_DUMP, { dev: ifname });
	m.network_noise(labels, res.ok ? noise_at(res.data, wif.wiphy_freq) : NaN);

	if (!with_stations)
		return null;

	m.stations_total(labels, length(stations));
	for (let sta in stations)
		station(m, radio, ifname, sta);

	return null;
}

export function collect(deps, out, options) {
	let res = deps.ubus.call('network.wireless', 'status');

	if (!res.ok)
		return res;

	let status = res.data;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'network.wireless status: not an object');

	let m = metrics(out);
	let failure = null;

	for (let radio, r in status) {
		let rc = r?.config ?? {};

		m.radio_info({ radio, htmode: rc.htmode, channel: rc.channel, country: rc.country }, 1);

		for (let iface in r?.interfaces ?? []) {
			if (type(iface?.ifname) != 'string')
				continue;

			let fail = network(deps.nl80211, m, radio, iface, options.stations);
			failure ??= fail;
		}
	}

	return failure ?? Result.ok();
};
