'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/extra/wifi.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The upstream ucode exporter's wifi collector: each radio and network in ubus
// network.wireless status, with what nl80211 knows of the network's interface,
// stations and channel; NaN for the averages of a network without stations.
// Where node_exporter's wifi collector (collector/wifi_linux.go) has a metric,
// this one has its name, help and labels (device, the interface, and
// mac_address, the station's), and a radio label besides; the rest are
// node_wifi_* too, in base units: bits per second, seconds, a ratio.
//
// With option `stations` (on by default) it also writes one sample per station
// to the node_wifi_station_* families, which the wifi_stations collector writes
// too (without the `radio` label). Install one of the two, or set `stations`
// off here, or each station is exported twice.
//
// An interface nl80211 cannot answer for is left out and fails the collector
// once the other interfaces are written. A driver without a channel survey
// gives no noise reading: NaN, as upstream, and not a failure.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'wifi',
	title: 'Wi-Fi',
	help: 'Wi-Fi radios, networks and stations, from ubus network.wireless and nl80211.',
	needs: [ 'ubus', 'nl80211' ],
	options: {
		stations: { default: true, help: 'Per-station metrics: signal, rates and traffic of each client.' },
	},
};

// The mode of an interface by its NL80211_IFTYPE_* value.
const IFTYPES = [
	'Unknown', 'Ad-Hoc', 'Client', 'Master', 'Master (VLAN)', 'WDS', 'Monitor',
	'Mesh Point', 'P2P Client', 'P2P Go', 'P2P Device', 'OCB',
];

// nl80211's bitrates are in units of 100 kbit/s, its expected throughput in kbit/s.
const BITRATE_UNIT = 100000;
const KBIT = 1000;

// node_exporter's station families, and the expected throughput: the same
// as the wifi_stations collector's.
function station_metrics(out) {
	return {
		connected: out.counter('node_wifi_station_connected_seconds_total', 'The total number of seconds a station has been connected to an access point.'),
		inactive: out.gauge('node_wifi_station_inactive_seconds', 'The number of seconds since any wireless activity has occurred on a station.'),
		rx_bitrate: out.gauge('node_wifi_station_receive_bits_per_second', 'The current WiFi receive bitrate of a station, in bits per second.'),
		tx_bitrate: out.gauge('node_wifi_station_transmit_bits_per_second', 'The current WiFi transmit bitrate of a station, in bits per second.'),
		rx_bytes: out.counter('node_wifi_station_receive_bytes_total', 'The total number of bytes received by a WiFi station.'),
		tx_bytes: out.counter('node_wifi_station_transmit_bytes_total', 'The total number of bytes transmitted by a WiFi station.'),
		signal: out.gauge('node_wifi_station_signal_dbm', 'The current WiFi signal strength, in decibel-milliwatts (dBm).'),
		tx_retries: out.counter('node_wifi_station_transmit_retries_total', 'The total number of times a station has had to retry while sending a packet.'),
		tx_failed: out.counter('node_wifi_station_transmit_failed_total', 'The total number of times a station has failed to send a packet.'),
		beacon_loss: out.counter('node_wifi_station_beacon_loss_total', 'The total number of times a station has detected a beacon loss.'),
		tx_packets: out.counter('node_wifi_station_transmitted_packets_total', 'The total number of packets transmitted by a station.'),
		rx_packets: out.counter('node_wifi_station_received_packets_total', 'The total number of packets received by a station.'),
		expected_throughput: out.gauge('node_wifi_station_expected_throughput_bits_per_second', 'Expected throughput to the station, in bits per second.'),
	};
}

function metrics(out) {
	return {
		radio_info: out.gauge('node_wifi_radio_info', 'A Wi-Fi radio, by its mode, channel and country.'),
		frequency: out.gauge('node_wifi_interface_frequency_hertz', 'The current frequency a WiFi interface is operating at, in hertz.'),
		network_info: out.gauge('node_wifi_network_info', 'A Wi-Fi network, by its SSID, BSSID and mode.'),
		network_quality: out.gauge('node_wifi_network_quality_ratio', 'Signal quality of the network\'s stations, from 0 (-110 dBm) to 1 (-40 dBm).'),
		network_bitrate: out.gauge('node_wifi_network_transmit_bits_per_second', 'Average transmit bitrate to the network\'s stations, in bits per second.'),
		network_noise: out.gauge('node_wifi_network_noise_dbm', 'Noise on the network\'s channel, in dBm.'),
		network_signal: out.gauge('node_wifi_network_signal_dbm', 'Average signal of the network\'s stations, in dBm.'),
		stations: out.gauge('node_wifi_stations', 'Stations associated with the interface.'),
		...station_metrics(out),
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

// The upstream exporter's signal quality, (signal + 110) / 70, as a ratio
// where it was a percentage: -110 dBm is 0, -40 dBm 1.
export function quality(signal) {
	return (signal + 110) / 70.0;
};

function noise_at(survey, freq) {
	for (let s in (type(survey) == 'array' ? survey : [])) {
		if (s?.survey_info?.frequency == freq)
			return s.survey_info.noise || NaN;
	}

	return NaN;
}

// A value in milliseconds in seconds, or null for none.
function seconds(ms) {
	return type(ms) in [ 'int', 'double' ] ? ms / 1000.0 : null;
}

// A field the driver does not report is left out, and so are the bitrates and
// the expected throughput when it reports 0.
function station(m, radio, device, sta) {
	let labels = { radio, device, mac_address: sta?.mac };
	let info = sta?.sta_info ?? {};

	m.connected(labels, info.connected_time);
	m.inactive(labels, seconds(info.inactive_time));
	if (info.rx_bitrate?.bitrate32)
		m.rx_bitrate(labels, info.rx_bitrate.bitrate32 * BITRATE_UNIT);
	if (info.tx_bitrate?.bitrate32)
		m.tx_bitrate(labels, info.tx_bitrate.bitrate32 * BITRATE_UNIT);
	m.rx_bytes(labels, info.rx_bytes64 ?? info.rx_bytes);
	m.tx_bytes(labels, info.tx_bytes64 ?? info.tx_bytes);
	m.signal(labels, info.signal);
	m.tx_retries(labels, info.tx_retries);
	m.tx_failed(labels, info.tx_failed);
	m.beacon_loss(labels, info.beacon_loss);
	m.tx_packets(labels, info.tx_packets);
	m.rx_packets(labels, info.rx_packets);
	if (info.expected_throughput)
		m.expected_throughput(labels, info.expected_throughput * KBIT);
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

	let labels = { radio, device: ifname };

	if (type(wif.wiphy_freq) == 'int')
		m.frequency(labels, wif.wiphy_freq * 1000000);

	m.network_info({
		...labels,
		ssid: nc.ssid || nc.mesh_id,
		bssid: wif.mac,
		mode: IFTYPES[wif.iftype],
	}, 1);

	res = nl.request(C.NL80211_CMD_GET_STATION, C.NLM_F_DUMP, { dev: ifname });
	if (!res.ok)
		return failed(res, ifname);

	// An empty dump is a null reply.
	let stations = type(res.data) == 'array' ? res.data : [];
	let bitrate = mean(stations, (s) => s?.sta_info?.tx_bitrate?.bitrate32);
	let signal = mean(stations, (s) => s?.sta_info?.signal);

	m.network_bitrate(labels, bitrate * BITRATE_UNIT);
	m.network_signal(labels, signal);
	m.network_quality(labels, quality(signal));

	res = nl.request(C.NL80211_CMD_GET_SURVEY, C.NLM_F_DUMP, { dev: ifname });
	m.network_noise(labels, res.ok ? noise_at(res.data, wif.wiphy_freq) : NaN);

	if (!with_stations)
		return null;

	m.stations(labels, length(stations));
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
