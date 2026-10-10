'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as wifi from 'prometheus.collectors.wifi';
import * as rpc from 'prometheus.exporter.rpc';
import { format_value } from 'prometheus.exporter.exposition';

// caju-ap: radio_2G serves phy0-ap0 (one station), radio_5G phy1-ap0 (none,
// an empty dump) and phy1-ap1 (four).
const IFACES = [ 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ];
const CMDS = [ 'NL80211_CMD_GET_INTERFACE', 'NL80211_CMD_GET_STATION', 'NL80211_CMD_GET_SURVEY' ];

// What the service's ubus object answers on the AP: netifd's wireless status
// without its keys.
const WIRELESS = fixtures.ubus('caju-ap', 'prometheus-exporter', 'wireless');

// The object's reply of netifd's `status`, as its method makes it.
function wireless(status) {
	return { 'prometheus-exporter:wireless': rpc.wireless(status) };
}
const AP = {};
for (let cmd in CMDS)
	for (let dev in IFACES)
		AP[`${cmd}:${dev}`] = json(fixtures.file('caju-ap', `/nl80211/${cmd}.${dev}.json`));

function ap(overrides) {
	return {
		ubus: { data: { 'prometheus-exporter:wireless': WIRELESS } },
		nl80211: { data: { ...AP, ...(overrides?.data ?? {}) }, errors: overrides?.errors ?? {} },
		options: overrides?.options,
	};
}

const NETWORKS = [
	'# HELP node_wifi_radio_info A Wi-Fi radio, by its mode, channel and country.',
	'# TYPE node_wifi_radio_info gauge',
	'node_wifi_radio_info{radio="radio_2G",htmode="HE20",channel="11",country="BR"} 1',
	'node_wifi_radio_info{radio="radio_5G",htmode="HE80",channel="149",country="BR"} 1',
	'# HELP node_wifi_radio_up Whether netifd has the Wi-Fi radio up (1) or not (0).',
	'# TYPE node_wifi_radio_up gauge',
	'node_wifi_radio_up{radio="radio_2G"} 1',
	'node_wifi_radio_up{radio="radio_5G"} 1',
	'# HELP node_wifi_radio_disabled Whether the Wi-Fi radio is disabled in the wireless config (1) or not (0).',
	'# TYPE node_wifi_radio_disabled gauge',
	'node_wifi_radio_disabled{radio="radio_2G"} 0',
	'node_wifi_radio_disabled{radio="radio_5G"} 0',
	'# HELP node_wifi_interface_frequency_hertz The current frequency a WiFi interface is operating at, in hertz.',
	'# TYPE node_wifi_interface_frequency_hertz gauge',
	'node_wifi_interface_frequency_hertz{radio="radio_2G",device="phy0-ap0"} 2462000000',
	'node_wifi_interface_frequency_hertz{radio="radio_5G",device="phy1-ap0"} 5745000000',
	'node_wifi_interface_frequency_hertz{radio="radio_5G",device="phy1-ap1"} 5745000000',
	'# HELP node_wifi_network_info A Wi-Fi network, by its SSID, BSSID and mode.',
	'# TYPE node_wifi_network_info gauge',
	'node_wifi_network_info{radio="radio_2G",device="phy0-ap0",ssid="iot",bssid="02:00:00:00:a0:01",mode="Master"} 1',
	'node_wifi_network_info{radio="radio_5G",device="phy1-ap0",ssid="guest",bssid="02:00:00:00:a0:02",mode="Master"} 1',
	'node_wifi_network_info{radio="radio_5G",device="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
	'# HELP node_wifi_network_quality_ratio Signal quality of the network\'s stations, from 0 (-110 dBm or weaker) to 1 (-40 dBm or stronger).',
	'# TYPE node_wifi_network_quality_ratio gauge',
	'node_wifi_network_quality_ratio{radio="radio_2G",device="phy0-ap0"} 0.6714285714285714',
	'node_wifi_network_quality_ratio{radio="radio_5G",device="phy1-ap0"} NaN',
	'node_wifi_network_quality_ratio{radio="radio_5G",device="phy1-ap1"} 0.4642857142857143',
	'# HELP node_wifi_network_transmit_bits_per_second Average transmit bitrate to the network\'s stations, in bits per second.',
	'# TYPE node_wifi_network_transmit_bits_per_second gauge',
	'node_wifi_network_transmit_bits_per_second{radio="radio_2G",device="phy0-ap0"} 65000000',
	'node_wifi_network_transmit_bits_per_second{radio="radio_5G",device="phy1-ap0"} NaN',
	'node_wifi_network_transmit_bits_per_second{radio="radio_5G",device="phy1-ap1"} 423300000',
	'# HELP node_wifi_network_noise_dbm Noise on the network\'s channel, in dBm.',
	'# TYPE node_wifi_network_noise_dbm gauge',
	'node_wifi_network_noise_dbm{radio="radio_2G",device="phy0-ap0"} -88',
	'node_wifi_network_noise_dbm{radio="radio_5G",device="phy1-ap0"} -92',
	'node_wifi_network_noise_dbm{radio="radio_5G",device="phy1-ap1"} -91',
	'# HELP node_wifi_network_signal_dbm Average signal of the network\'s stations, in dBm.',
	'# TYPE node_wifi_network_signal_dbm gauge',
	'node_wifi_network_signal_dbm{radio="radio_2G",device="phy0-ap0"} -63',
	'node_wifi_network_signal_dbm{radio="radio_5G",device="phy1-ap0"} NaN',
	'node_wifi_network_signal_dbm{radio="radio_5G",device="phy1-ap1"} -77.5',
];

// The channel each interface is on, as its survey says: the time the radio
// was on it, sensed it busy, received and transmitted, in seconds.
const CHANNEL = [
	'# HELP node_wifi_channel_active_seconds_total Time the radio has been on the interface\'s channel, in seconds.',
	'# TYPE node_wifi_channel_active_seconds_total counter',
	'node_wifi_channel_active_seconds_total{radio="radio_2G",device="phy0-ap0"} 12078.755',
	'node_wifi_channel_active_seconds_total{radio="radio_5G",device="phy1-ap0"} 12079.591',
	'node_wifi_channel_active_seconds_total{radio="radio_5G",device="phy1-ap1"} 12079.616',
	'# HELP node_wifi_channel_busy_seconds_total Time the radio has sensed the interface\'s channel busy, in seconds.',
	'# TYPE node_wifi_channel_busy_seconds_total counter',
	'node_wifi_channel_busy_seconds_total{radio="radio_2G",device="phy0-ap0"} 7969.429',
	'node_wifi_channel_busy_seconds_total{radio="radio_5G",device="phy1-ap0"} 432.731',
	'node_wifi_channel_busy_seconds_total{radio="radio_5G",device="phy1-ap1"} 432.731',
	'# HELP node_wifi_channel_receive_seconds_total Time the radio has spent receiving on the interface\'s channel, in seconds.',
	'# TYPE node_wifi_channel_receive_seconds_total counter',
	'node_wifi_channel_receive_seconds_total{radio="radio_2G",device="phy0-ap0"} 7181.722',
	'node_wifi_channel_receive_seconds_total{radio="radio_5G",device="phy1-ap0"} 294.822',
	'node_wifi_channel_receive_seconds_total{radio="radio_5G",device="phy1-ap1"} 294.822',
	'# HELP node_wifi_channel_transmit_seconds_total Time the radio has spent transmitting on the interface\'s channel, in seconds.',
	'# TYPE node_wifi_channel_transmit_seconds_total counter',
	'node_wifi_channel_transmit_seconds_total{radio="radio_2G",device="phy0-ap0"} 57.349',
	'node_wifi_channel_transmit_seconds_total{radio="radio_5G",device="phy1-ap0"} 134.859',
	'node_wifi_channel_transmit_seconds_total{radio="radio_5G",device="phy1-ap1"} 134.859',
];

function sta(dev, mac) {
	return `{radio="${dev == 'phy0-ap0' ? 'radio_2G' : 'radio_5G'}",device="${dev}",mac_address="02:00:00:00:00:${mac}"}`;
}

// How many stations each interface has, with the option stations on or off.
const COUNTS = [
	'# HELP node_wifi_stations Stations associated with the interface.',
	'# TYPE node_wifi_stations gauge',
	'node_wifi_stations{radio="radio_2G",device="phy0-ap0"} 1',
	'node_wifi_stations{radio="radio_5G",device="phy1-ap0"} 0',
	'node_wifi_stations{radio="radio_5G",device="phy1-ap1"} 4',
];

const STATIONS = [
	...COUNTS,
	'# HELP node_wifi_station_connected_seconds_total The total number of seconds a station has been connected to an access point.',
	'# TYPE node_wifi_station_connected_seconds_total counter',
	'node_wifi_station_connected_seconds_total' + sta('phy0-ap0', '01') + ' 12053',
	'node_wifi_station_connected_seconds_total' + sta('phy1-ap1', '03') + ' 12024',
	'node_wifi_station_connected_seconds_total' + sta('phy1-ap1', '02') + ' 8628',
	'node_wifi_station_connected_seconds_total' + sta('phy1-ap1', '04') + ' 5271',
	'node_wifi_station_connected_seconds_total' + sta('phy1-ap1', '05') + ' 5265',
	'# HELP node_wifi_station_inactive_seconds The number of seconds since any wireless activity has occurred on a station.',
	'# TYPE node_wifi_station_inactive_seconds gauge',
	'node_wifi_station_inactive_seconds' + sta('phy0-ap0', '01') + ' 0.01',
	'node_wifi_station_inactive_seconds' + sta('phy1-ap1', '03') + ' 23.31',
	'node_wifi_station_inactive_seconds' + sta('phy1-ap1', '02') + ' 0.14',
	'node_wifi_station_inactive_seconds' + sta('phy1-ap1', '04') + ' 37.5',
	'node_wifi_station_inactive_seconds' + sta('phy1-ap1', '05') + ' 15.2',
	'# HELP node_wifi_station_receive_bits_per_second The current WiFi receive bitrate of a station, in bits per second.',
	'# TYPE node_wifi_station_receive_bits_per_second gauge',
	'node_wifi_station_receive_bits_per_second' + sta('phy0-ap0', '01') + ' 72200000',
	'node_wifi_station_receive_bits_per_second' + sta('phy1-ap1', '03') + ' 432300000',
	'node_wifi_station_receive_bits_per_second' + sta('phy1-ap1', '02') + ' 144100000',
	'node_wifi_station_receive_bits_per_second' + sta('phy1-ap1', '04') + ' 8100000',
	'node_wifi_station_receive_bits_per_second' + sta('phy1-ap1', '05') + ' 144100000',
	'# HELP node_wifi_station_transmit_bits_per_second The current WiFi transmit bitrate of a station, in bits per second.',
	'# TYPE node_wifi_station_transmit_bits_per_second gauge',
	'node_wifi_station_transmit_bits_per_second' + sta('phy0-ap0', '01') + ' 65000000',
	'node_wifi_station_transmit_bits_per_second' + sta('phy1-ap1', '03') + ' 288200000',
	'node_wifi_station_transmit_bits_per_second' + sta('phy1-ap1', '02') + ' 648500000',
	'node_wifi_station_transmit_bits_per_second' + sta('phy1-ap1', '04') + ' 324200000',
	'node_wifi_station_transmit_bits_per_second' + sta('phy1-ap1', '05') + ' 432300000',
	'# HELP node_wifi_station_receive_bytes_total The total number of bytes received by a WiFi station.',
	'# TYPE node_wifi_station_receive_bytes_total counter',
	'node_wifi_station_receive_bytes_total' + sta('phy0-ap0', '01') + ' 14613247',
	'node_wifi_station_receive_bytes_total' + sta('phy1-ap1', '03') + ' 4873383',
	'node_wifi_station_receive_bytes_total' + sta('phy1-ap1', '02') + ' 48422804',
	'node_wifi_station_receive_bytes_total' + sta('phy1-ap1', '04') + ' 3744045',
	'node_wifi_station_receive_bytes_total' + sta('phy1-ap1', '05') + ' 2422352',
	'# HELP node_wifi_station_transmit_bytes_total The total number of bytes transmitted by a WiFi station.',
	'# TYPE node_wifi_station_transmit_bytes_total counter',
	'node_wifi_station_transmit_bytes_total' + sta('phy0-ap0', '01') + ' 43766742',
	'node_wifi_station_transmit_bytes_total' + sta('phy1-ap1', '03') + ' 9616361',
	'node_wifi_station_transmit_bytes_total' + sta('phy1-ap1', '02') + ' 480803379',
	'node_wifi_station_transmit_bytes_total' + sta('phy1-ap1', '04') + ' 13015496',
	'node_wifi_station_transmit_bytes_total' + sta('phy1-ap1', '05') + ' 103585072',
	'# HELP node_wifi_station_signal_dbm The current WiFi signal strength, in decibel-milliwatts (dBm).',
	'# TYPE node_wifi_station_signal_dbm gauge',
	'node_wifi_station_signal_dbm' + sta('phy0-ap0', '01') + ' -63',
	'node_wifi_station_signal_dbm' + sta('phy1-ap1', '03') + ' -73',
	'node_wifi_station_signal_dbm' + sta('phy1-ap1', '02') + ' -81',
	'node_wifi_station_signal_dbm' + sta('phy1-ap1', '04') + ' -84',
	'node_wifi_station_signal_dbm' + sta('phy1-ap1', '05') + ' -72',
	'# HELP node_wifi_station_transmit_retries_total The total number of times a station has had to retry while sending a packet.',
	'# TYPE node_wifi_station_transmit_retries_total counter',
	'node_wifi_station_transmit_retries_total' + sta('phy0-ap0', '01') + ' 11791',
	'node_wifi_station_transmit_retries_total' + sta('phy1-ap1', '03') + ' 3375',
	'node_wifi_station_transmit_retries_total' + sta('phy1-ap1', '02') + ' 22470',
	'node_wifi_station_transmit_retries_total' + sta('phy1-ap1', '04') + ' 1219',
	'node_wifi_station_transmit_retries_total' + sta('phy1-ap1', '05') + ' 5603',
	'# HELP node_wifi_station_transmit_failed_total The total number of times a station has failed to send a packet.',
	'# TYPE node_wifi_station_transmit_failed_total counter',
	'node_wifi_station_transmit_failed_total' + sta('phy0-ap0', '01') + ' 11813',
	'node_wifi_station_transmit_failed_total' + sta('phy1-ap1', '03') + ' 3376',
	'node_wifi_station_transmit_failed_total' + sta('phy1-ap1', '02') + ' 22470',
	'node_wifi_station_transmit_failed_total' + sta('phy1-ap1', '04') + ' 1219',
	'node_wifi_station_transmit_failed_total' + sta('phy1-ap1', '05') + ' 5603',
	'# HELP node_wifi_station_transmitted_packets_total The total number of packets transmitted by a station.',
	'# TYPE node_wifi_station_transmitted_packets_total counter',
	'node_wifi_station_transmitted_packets_total' + sta('phy0-ap0', '01') + ' 47105',
	'node_wifi_station_transmitted_packets_total' + sta('phy1-ap1', '03') + ' 14302',
	'node_wifi_station_transmitted_packets_total' + sta('phy1-ap1', '02') + ' 418802',
	'node_wifi_station_transmitted_packets_total' + sta('phy1-ap1', '04') + ' 14812',
	'node_wifi_station_transmitted_packets_total' + sta('phy1-ap1', '05') + ' 72070',
	'# HELP node_wifi_station_received_packets_total The total number of packets received by a station.',
	'# TYPE node_wifi_station_received_packets_total counter',
	'node_wifi_station_received_packets_total' + sta('phy0-ap0', '01') + ' 354610',
	'node_wifi_station_received_packets_total' + sta('phy1-ap1', '03') + ' 15846',
	'node_wifi_station_received_packets_total' + sta('phy1-ap1', '02') + ' 153592',
	'node_wifi_station_received_packets_total' + sta('phy1-ap1', '04') + ' 16535',
	'node_wifi_station_received_packets_total' + sta('phy1-ap1', '05') + ' 10924',
	'# HELP node_wifi_station_expected_throughput_bits_per_second Expected throughput to the station, in bits per second.',
	'# TYPE node_wifi_station_expected_throughput_bits_per_second gauge',
	'node_wifi_station_expected_throughput_bits_per_second' + sta('phy0-ap0', '01') + ' 58576000',
	'node_wifi_station_expected_throughput_bits_per_second' + sta('phy1-ap1', '03') + ' 252360000',
	'node_wifi_station_expected_throughput_bits_per_second' + sta('phy1-ap1', '02') + ' 564848000',
	'node_wifi_station_expected_throughput_bits_per_second' + sta('phy1-ap1', '04') + ' 283752000',
	'node_wifi_station_expected_throughput_bits_per_second' + sta('phy1-ap1', '05') + ' 382872000',
];

// One radio with one AP interface whose station dump has these signals and
// transmit bitrates (in 100 kbit/s).
function one_network(signals, bitrates) {
	let dump = [];

	for (let i, signal in signals)
		push(dump, {
			mac: sprintf('02:00:00:00:01:%02x', i),
			sta_info: { signal, tx_bitrate: { bitrate32: bitrates[i] } },
		});

	return {
		ubus: { data: wireless({
			radio0: { config: { channel: '36' }, interfaces: [ { ifname: 'wlan0', config: { ssid: 'lab' } } ] },
		}) },
		nl80211: { data: {
			'NL80211_CMD_GET_INTERFACE:wlan0': { mac: '02:00:00:00:b0:00', iftype: 3, wiphy_freq: 5180 },
			'NL80211_CMD_GET_STATION:wlan0': length(dump) ? dump : null,
			'NL80211_CMD_GET_SURVEY:wlan0': [ { survey_info: { frequency: 5180, noise: -95 } } ],
		} },
	};
}

function sample(lines, name) {
	for (let l in lines)
		if (index(l, name + '{') == 0)
			return +split(l, ' ')[1];
	return null;
}


// A request refused as ucode's netlink modules refuse one: false, and an
// error that error() clears as it reads it.
function refused(why) {
	let error = why;

	return {
		request: () => false,
		error: function() {
			let e = error;
			error = null;
			return e;
		},
	};
}

describe('collectors.wifi', () => {
	it('exports the radios, networks and stations of the caju AP', () => {
		with_collector(wifi, ap(), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ ...NETWORKS, ...STATIONS, ...CHANNEL ], r.lines);
		});
	});

	it('leaves each station out with option stations off, and still counts them', () => {
		with_collector(wifi, ap({ options: { stations: '0' } }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ ...NETWORKS, ...COUNTS, ...CHANNEL ], r.lines);
		});
	});

	it('asks the service\'s ubus object, never netifd\'s wireless status, which holds every network\'s key', () => {
		assert.match({ 'prometheus-exporter': [ 'wireless' ] }, wifi.meta.ubus);
	});

	it('has nothing to observe where netifd has no radio, or no network.wireless', () => {
		with_collector(wifi, { ubus: { data: wireless({}) } }, (r) => {
			assert.match({ ok: true, none: 'no wireless radios', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('still observes a radio without interfaces, and says it is down, or disabled', () => {
		with_collector(wifi, { ubus: { data: wireless({ radio0: { up: false, disabled: true, config: { channel: '1' }, interfaces: [] } }) } }, (r) => {
			assert.match([ true, null ], [ r.result.ok, r.result.none ]);
			assert.match(contains([
				'node_wifi_radio_info{radio="radio0",channel="1"} 1',
				'node_wifi_radio_up{radio="radio0"} 0',
				'node_wifi_radio_disabled{radio="radio0"} 1',
			]), r.lines);
		});
	});

	it('writes neither up nor disabled of a radio whose status does not say', () => {
		with_collector(wifi, { ubus: { data: wireless({ radio0: { config: {}, interfaces: [] } }) } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], filter(r.lines, (l) => match(l, /^node_wifi_radio_(up|disabled)\{/)));
		});
	});

	it('fails with SOURCE_INVALID when the object says it could not ask netifd', () => {
		let c = { ubus: { data: { 'prometheus-exporter:wireless': { error: 'UBUS_CALL_FAILED', message: 'UBUS_CALL_FAILED (network.wireless status: Request timed out)' } } } };

		with_collector(wifi, c, (r) => {
			assert.match({ ok: false, error: 'SOURCE_INVALID', details: 'prometheus-exporter wireless: UBUS_CALL_FAILED (network.wireless status: Request timed out)' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('passes a failed call of the object on', () => {
		with_collector(wifi, { ubus: { errors: { 'prometheus-exporter:wireless': 'Request timed out' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('fails with NEED_MISSING without ucode-mod-nl80211', () => {
		with_collector(wifi, { ...ap(), no_nl80211: true }, (r) => {
			assert.match({ ok: false, error: 'NEED_MISSING' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('writes the other networks when one station dump fails, and fails', () => {
		let cfg = ap({ errors: { 'NL80211_CMD_GET_STATION:phy1-ap1': 'Operation not supported' } });

		with_collector(wifi, cfg, (r) => {
			assert.match({ ok: false, error: 'NL80211_FAILED', details: 'phy1-ap1: Operation not supported' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match(contains([
				'node_wifi_network_info{radio="radio_5G",device="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
				'node_wifi_network_signal_dbm{radio="radio_2G",device="phy0-ap0"} -63',
				'node_wifi_stations{radio="radio_5G",device="phy1-ap0"} 0',
			]), r.lines);
			assert.match([
				'node_wifi_interface_frequency_hertz{radio="radio_5G",device="phy1-ap1"} 5745000000',
				'node_wifi_network_info{radio="radio_5G",device="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
			], filter(r.lines, (l) => index(l, 'device="phy1-ap1"') >= 0));
		});
	});

	it('says why nl80211 refused a request', () => {
		let cfg = ap();
		cfg.nl80211.behavior = refused('No such device');

		with_collector(wifi, cfg, (r) => {
			assert.match({ ok: false, error: 'NL80211_FAILED', details: 'phy0-ap0: No such device' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
		});
	});

	it('leaves out a network nl80211 does not know', () => {
		with_collector(wifi, ap({ errors: { 'NL80211_CMD_GET_INTERFACE:phy0-ap0': 'No such device' } }), (r) => {
			assert.match({ error: 'NL80211_FAILED', details: 'phy0-ap0: No such device' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], filter(r.lines, (l) => index(l, 'phy0-ap0') >= 0));
			assert.match(contains([ 'node_wifi_stations{radio="radio_5G",device="phy1-ap1"} 4' ]), r.lines);
		});
	});

	it('writes NaN noise, and succeeds, without a channel survey', () => {
		let errors = {};
		for (let dev in IFACES)
			errors[`NL80211_CMD_GET_SURVEY:${dev}`] = 'Operation not supported';

		with_collector(wifi, ap({ errors }), (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([
				'node_wifi_network_noise_dbm{radio="radio_2G",device="phy0-ap0"} NaN',
				'node_wifi_network_noise_dbm{radio="radio_5G",device="phy1-ap1"} NaN',
			]), r.lines);
		});
	});

	it('writes the channel\'s times the driver reports, and none without a survey of it', () => {
		let cfg = one_network([], []);
		cfg.nl80211.data['NL80211_CMD_GET_SURVEY:wlan0'] = [
			{ survey_info: { frequency: 5180, noise: -95, time: 1500, busy: 250 } },
			{ survey_info: { frequency: 5200, time: 99, busy: 99, time_rx: 99, time_tx: 99 } },
		];

		with_collector(wifi, cfg, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_wifi_channel_active_seconds_total{radio="radio0",device="wlan0"} 1.5',
				'node_wifi_channel_busy_seconds_total{radio="radio0",device="wlan0"} 0.25',
			], filter(r.lines, (l) => index(l, 'node_wifi_channel_') == 0));
		});

		cfg.nl80211.data['NL80211_CMD_GET_SURVEY:wlan0'] = [ { survey_info: { frequency: 2412, time: 7 } } ];
		with_collector(wifi, cfg, (r) => {
			assert.match([ true, [] ], [ r.result.ok, filter(r.lines, (l) => index(l, 'node_wifi_channel_') == 0) ]);
		});
	});

	prop('converts the channel\'s times from milliseconds to seconds',
		gen.tuple(gen.int(0, 4000000000000), gen.int(0, 4000000000000), gen.int(0, 4000000000000), gen.int(0, 4000000000000)), (t) => {
			let cfg = one_network([], []);
			cfg.nl80211.data['NL80211_CMD_GET_SURVEY:wlan0'] = [
				{ survey_info: { frequency: 5180, time: t[0], busy: t[1], time_rx: t[2], time_tx: t[3] } },
			];

			with_collector(wifi, cfg, (r) => {
				assert.match(map(t, (ms) => format_value(ms / 1000.0)), map([
					'node_wifi_channel_active_seconds_total', 'node_wifi_channel_busy_seconds_total',
					'node_wifi_channel_receive_seconds_total', 'node_wifi_channel_transmit_seconds_total',
				], (n) => split(filter(r.lines, (l) => index(l, n + '{') == 0)[0], ' ')[1]));
			});
		});

	it('skips an interface without an ifname, as a radio that is down has', () => {
		let cfg = one_network([], []);
		push(cfg.ubus.data['prometheus-exporter:wireless'].radios.radio0.interfaces, { config: {} });

		with_collector(wifi, cfg, (r) => {
			assert.match(true, r.result.ok);
			assert.match(1, length(filter(r.lines, (l) => index(l, 'node_wifi_network_info{') == 0)));
		});
	});

	prop('averages the stations\' signal and bitrate (in bits per second), and counts them',
		gen.array(gen.tuple(gen.int(-95, -20), gen.int(1, 24000)), { min_len: 1, max_len: 12 }), (stations) => {
			let signals = map(stations, (s) => s[0]);
			let bitrates = map(stations, (s) => s[1]);

			with_collector(wifi, one_network(signals, bitrates), (r) => {
				let signal = sample(r.lines, 'node_wifi_network_signal_dbm');
				let bitrate = sample(r.lines, 'node_wifi_network_transmit_bits_per_second');
				let quality = sample(r.lines, 'node_wifi_network_quality_ratio');

				assert.match(true, r.result.ok);
				assert.match(length(stations), sample(r.lines, 'node_wifi_stations'));
				assert.match(true, signal >= min(...signals) && signal <= max(...signals), `${signal}`);
				assert.match(true, bitrate >= min(...bitrates) * 100000 && bitrate <= max(...bitrates) * 100000, `${bitrate}`);
				let error = quality - min(1, max(0, (signal + 110) / 70.0));

				assert.match(true, error > -1e-6 && error < 1e-6, `${quality}`);
			});
		});

	it('writes NaN averages for a network without stations', () => {
		with_collector(wifi, one_network([], []), (r) => {
			assert.match(contains([
				'node_wifi_interface_frequency_hertz{radio="radio0",device="wlan0"} 5180000000',
				'node_wifi_network_quality_ratio{radio="radio0",device="wlan0"} NaN',
				'node_wifi_network_transmit_bits_per_second{radio="radio0",device="wlan0"} NaN',
				'node_wifi_network_noise_dbm{radio="radio0",device="wlan0"} -95',
				'node_wifi_network_signal_dbm{radio="radio0",device="wlan0"} NaN',
				'node_wifi_stations{radio="radio0",device="wlan0"} 0',
			]), r.lines);
		});
	});

	it('gives the quality as a ratio: 0 at -110 dBm, 1 at -40 dBm', () => {
		assert.match([ 0.0, 0.5, 1.0 ], [ wifi.quality(-110), wifi.quality(-75), wifi.quality(-40) ]);
	});

	it('keeps the quality from 0 to 1 past those signals, and NaN for no signal', () => {
		assert.match([ 1.0, 1.0, 0.0, 0.0 ], [ wifi.quality(-39), wifi.quality(-20), wifi.quality(-111), wifi.quality(-150) ]);
		let nan = wifi.quality(NaN);
		assert.match(true, nan != nan);
	});

	prop('converts a station\'s times to seconds and its rates to bits per second',
		gen.tuple(gen.int(0, 10000000), gen.int(1, 50000), gen.int(1, 50000), gen.int(1, 5000000)), (x) => {
			let cfg = one_network([], []);
			cfg.nl80211.data['NL80211_CMD_GET_STATION:wlan0'] = [ { mac: '02:00:00:00:01:00', sta_info: {
				inactive_time: x[0], rx_bitrate: { bitrate32: x[1] }, tx_bitrate: { bitrate32: x[2] }, expected_throughput: x[3],
			} } ];

			with_collector(wifi, cfg, (r) => {
				assert.match(true, r.result.ok);
				let inactive = sample(r.lines, 'node_wifi_station_inactive_seconds');

				assert.match(true, inactive - x[0] / 1000.0 < 1e-9 && x[0] / 1000.0 - inactive < 1e-9, `${inactive}`);
				assert.match([ x[1] * 100000, x[2] * 100000, x[3] * 1000 ], [
					sample(r.lines, 'node_wifi_station_receive_bits_per_second'),
					sample(r.lines, 'node_wifi_station_transmit_bits_per_second'),
					sample(r.lines, 'node_wifi_station_expected_throughput_bits_per_second'),
				]);
			});
		});
});
