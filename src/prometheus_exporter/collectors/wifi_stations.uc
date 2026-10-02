'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/wifi_stations.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's wifi_stations collector: the stations of each interface in
// ubus network.wireless status. Lua read them through iwinfo; this reads the
// nl80211 station dump iwinfo makes, and leaves out the signal, expected
// throughput and rates when the driver reports 0, as iwinfo did. The families
// are named as node_exporter's wifi collector (collector/wifi_linux.go) names
// them, with its {device, mac_address} labels and base units, as the wifi
// collector writes them.
//
// The wifi collector's `stations` option writes the same node_wifi_station_*
// families, with a `radio` label besides. Install one of the two, or set that
// option off, or each station is exported twice.
//
// An interface whose dump fails is left out, and fails the collector once the
// others are written.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as services from 'prometheus_exporter.services';

export const meta = {
	name: 'wifi_stations',
	title: 'Wi-Fi stations',
	help: 'Wi-Fi stations of each interface, from ubus network.wireless and nl80211.',
	needs: [ 'ubus', 'nl80211' ],
};

// nl80211's bitrates are in units of 100 kbit/s, its expected throughput in kbit/s.
const BITRATE_UNIT = 100000;
const KBIT = 1000;

// The wifi collector's families, in its order.
function metrics(out) {
	return {
		stations: out.gauge('node_wifi_stations', 'Stations associated with the interface.'),
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
		labels: out.labels,
	};
}

// A value in milliseconds in seconds, or null for none.
function seconds(ms) {
	return type(ms) in [ 'int', 'double' ] ? ms / 1000.0 : null;
}

function station(m, device, sta) {
	let labels = m.labels({ device, mac_address: sta?.mac });
	let info = sta?.sta_info ?? {};

	m.connected(labels, info.connected_time);
	m.inactive(labels, seconds(info.inactive_time));
	if (info.rx_bitrate?.bitrate32)
		m.rx_bitrate(labels, info.rx_bitrate.bitrate32 * BITRATE_UNIT);
	if (info.tx_bitrate?.bitrate32)
		m.tx_bitrate(labels, info.tx_bitrate.bitrate32 * BITRATE_UNIT);
	m.rx_bytes(labels, info.rx_bytes64 ?? info.rx_bytes);
	m.tx_bytes(labels, info.tx_bytes64 ?? info.tx_bytes);
	if (info.signal)
		m.signal(labels, info.signal);
	m.tx_retries(labels, info.tx_retries);
	m.tx_failed(labels, info.tx_failed);
	m.beacon_loss(labels, info.beacon_loss);
	m.tx_packets(labels, info.tx_packets);
	m.rx_packets(labels, info.rx_packets);
	if (info.expected_throughput)
		m.expected_throughput(labels, info.expected_throughput * KBIT);
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

	m.stations({ device: ifname }, length(stations));
	return null;
}

// A device without radios (no network.wireless object, or one without radios)
// or whose radios have no interface up has nothing to observe.
export function collect(deps, out) {
	let res = deps.ubus.call('network.wireless', 'status');

	if (services.object_missing(res))
		return Result.none('no wireless radios');
	if (!res.ok)
		return res;

	let status = res.data;
	if (type(status) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'network.wireless status: not an object');
	if (!length(status))
		return Result.none('no wireless radios');

	let ifnames = [];

	for (let radio, r in status)
		for (let iface in r?.interfaces ?? [])
			if (type(iface?.ifname) == 'string')
				push(ifnames, iface.ifname);

	if (!length(ifnames))
		return Result.none('no wireless interfaces');

	let m = metrics(out);
	let failure = null;

	for (let ifname in ifnames) {
		let fail = interface_stations(deps.nl80211, m, ifname);
		failure ??= fail;
	}

	return failure ?? Result.ok();
};
