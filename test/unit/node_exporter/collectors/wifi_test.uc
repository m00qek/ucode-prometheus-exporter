'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as wifi from 'node_exporter.collectors.wifi';

// caju-ap: radio_2G serves phy0-ap0 (one station), radio_5G phy1-ap0 (none,
// an empty dump) and phy1-ap1 (four).
const IFACES = [ 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ];
const CMDS = [ 'NL80211_CMD_GET_INTERFACE', 'NL80211_CMD_GET_STATION', 'NL80211_CMD_GET_SURVEY' ];

const WIRELESS = fixtures.ubus('caju-ap', 'network.wireless', 'status');
const AP = {};
for (let cmd in CMDS)
	for (let dev in IFACES)
		AP[`${cmd}:${dev}`] = json(fixtures.file('caju-ap', `/nl80211/${cmd}.${dev}.json`));

function ap(overrides) {
	return {
		ubus: { data: { 'network.wireless:status': WIRELESS } },
		nl80211: { data: { ...AP, ...(overrides?.data ?? {}) }, errors: overrides?.errors ?? {} },
		options: overrides?.options,
	};
}

const NETWORKS = [
	'# HELP wifi_radio_info A Wi-Fi radio, by its mode, channel and country.',
	'# TYPE wifi_radio_info gauge',
	'wifi_radio_info{radio="radio_2G",htmode="HE20",channel="11",country="BR"} 1',
	'wifi_radio_info{radio="radio_5G",htmode="HE80",channel="149",country="BR"} 1',
	'# HELP wifi_network_info A Wi-Fi network, by its SSID, BSSID and mode.',
	'# TYPE wifi_network_info gauge',
	'wifi_network_info{radio="radio_2G",ifname="phy0-ap0",ssid="iot",bssid="02:00:00:00:a0:01",mode="Master"} 1',
	'wifi_network_info{radio="radio_5G",ifname="phy1-ap0",ssid="guest",bssid="02:00:00:00:a0:02",mode="Master"} 1',
	'wifi_network_info{radio="radio_5G",ifname="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
	'# HELP wifi_network_quality Signal quality of the network\'s stations, in percent.',
	'# TYPE wifi_network_quality gauge',
	'wifi_network_quality{radio="radio_2G",ifname="phy0-ap0"} 67.142857142857',
	'wifi_network_quality{radio="radio_5G",ifname="phy1-ap0"} NaN',
	'wifi_network_quality{radio="radio_5G",ifname="phy1-ap1"} 46.428571428571',
	'# HELP wifi_network_bitrate Average transmit bitrate to the network\'s stations, in kbit/s.',
	'# TYPE wifi_network_bitrate gauge',
	'wifi_network_bitrate{radio="radio_2G",ifname="phy0-ap0"} 65000',
	'wifi_network_bitrate{radio="radio_5G",ifname="phy1-ap0"} NaN',
	'wifi_network_bitrate{radio="radio_5G",ifname="phy1-ap1"} 423300',
	'# HELP wifi_network_noise_dbm Noise on the network\'s channel, in dBm.',
	'# TYPE wifi_network_noise_dbm gauge',
	'wifi_network_noise_dbm{radio="radio_2G",ifname="phy0-ap0"} -88',
	'wifi_network_noise_dbm{radio="radio_5G",ifname="phy1-ap0"} -92',
	'wifi_network_noise_dbm{radio="radio_5G",ifname="phy1-ap1"} -91',
	'# HELP wifi_network_signal_dbm Average signal of the network\'s stations, in dBm.',
	'# TYPE wifi_network_signal_dbm gauge',
	'wifi_network_signal_dbm{radio="radio_2G",ifname="phy0-ap0"} -63',
	'wifi_network_signal_dbm{radio="radio_5G",ifname="phy1-ap0"} NaN',
	'wifi_network_signal_dbm{radio="radio_5G",ifname="phy1-ap1"} -77.5',
];

function sta(dev, mac) {
	return `{radio="${dev == 'phy0-ap0' ? 'radio_2G' : 'radio_5G'}",ifname="${dev}",mac="02:00:00:00:00:${mac}"}`;
}

const STATIONS = [
	'# HELP wifi_stations_total Stations associated with the network.',
	'# TYPE wifi_stations_total counter',
	'wifi_stations_total{radio="radio_2G",ifname="phy0-ap0"} 1',
	'wifi_stations_total{radio="radio_5G",ifname="phy1-ap0"} 0',
	'wifi_stations_total{radio="radio_5G",ifname="phy1-ap1"} 4',
	'# HELP wifi_station_inactive_milliseconds Time since the station was last active, in milliseconds.',
	'# TYPE wifi_station_inactive_milliseconds gauge',
	'wifi_station_inactive_milliseconds' + sta('phy0-ap0', '01') + ' 10',
	'wifi_station_inactive_milliseconds' + sta('phy1-ap1', '03') + ' 23310',
	'wifi_station_inactive_milliseconds' + sta('phy1-ap1', '02') + ' 140',
	'wifi_station_inactive_milliseconds' + sta('phy1-ap1', '04') + ' 37500',
	'wifi_station_inactive_milliseconds' + sta('phy1-ap1', '05') + ' 15200',
	'# HELP wifi_station_receive_bytes_total Bytes received from the station.',
	'# TYPE wifi_station_receive_bytes_total counter',
	'wifi_station_receive_bytes_total' + sta('phy0-ap0', '01') + ' 14613247',
	'wifi_station_receive_bytes_total' + sta('phy1-ap1', '03') + ' 4873383',
	'wifi_station_receive_bytes_total' + sta('phy1-ap1', '02') + ' 48422804',
	'wifi_station_receive_bytes_total' + sta('phy1-ap1', '04') + ' 3744045',
	'wifi_station_receive_bytes_total' + sta('phy1-ap1', '05') + ' 2422352',
	'# HELP wifi_station_transmit_bytes_total Bytes transmitted to the station.',
	'# TYPE wifi_station_transmit_bytes_total counter',
	'wifi_station_transmit_bytes_total' + sta('phy0-ap0', '01') + ' 43766742',
	'wifi_station_transmit_bytes_total' + sta('phy1-ap1', '03') + ' 9616361',
	'wifi_station_transmit_bytes_total' + sta('phy1-ap1', '02') + ' 480803379',
	'wifi_station_transmit_bytes_total' + sta('phy1-ap1', '04') + ' 13015496',
	'wifi_station_transmit_bytes_total' + sta('phy1-ap1', '05') + ' 103585072',
	'# HELP wifi_station_receive_packets_total Packets received from the station.',
	'# TYPE wifi_station_receive_packets_total counter',
	'wifi_station_receive_packets_total' + sta('phy0-ap0', '01') + ' 354610',
	'wifi_station_receive_packets_total' + sta('phy1-ap1', '03') + ' 15846',
	'wifi_station_receive_packets_total' + sta('phy1-ap1', '02') + ' 153592',
	'wifi_station_receive_packets_total' + sta('phy1-ap1', '04') + ' 16535',
	'wifi_station_receive_packets_total' + sta('phy1-ap1', '05') + ' 10924',
	'# HELP wifi_station_transmit_packets_total Packets transmitted to the station.',
	'# TYPE wifi_station_transmit_packets_total counter',
	'wifi_station_transmit_packets_total' + sta('phy0-ap0', '01') + ' 47105',
	'wifi_station_transmit_packets_total' + sta('phy1-ap1', '03') + ' 14302',
	'wifi_station_transmit_packets_total' + sta('phy1-ap1', '02') + ' 418802',
	'wifi_station_transmit_packets_total' + sta('phy1-ap1', '04') + ' 14812',
	'wifi_station_transmit_packets_total' + sta('phy1-ap1', '05') + ' 72070',
	'# HELP wifi_station_signal_dbm Signal of the station, in dBm.',
	'# TYPE wifi_station_signal_dbm gauge',
	'wifi_station_signal_dbm' + sta('phy0-ap0', '01') + ' -63',
	'wifi_station_signal_dbm' + sta('phy1-ap1', '03') + ' -73',
	'wifi_station_signal_dbm' + sta('phy1-ap1', '02') + ' -81',
	'wifi_station_signal_dbm' + sta('phy1-ap1', '04') + ' -84',
	'wifi_station_signal_dbm' + sta('phy1-ap1', '05') + ' -72',
	'# HELP wifi_station_receive_kilobits_per_second Bitrate of the last packet received from the station, in kbit/s.',
	'# TYPE wifi_station_receive_kilobits_per_second gauge',
	'wifi_station_receive_kilobits_per_second' + sta('phy0-ap0', '01') + ' 72200',
	'wifi_station_receive_kilobits_per_second' + sta('phy1-ap1', '03') + ' 432300',
	'wifi_station_receive_kilobits_per_second' + sta('phy1-ap1', '02') + ' 144100',
	'wifi_station_receive_kilobits_per_second' + sta('phy1-ap1', '04') + ' 8100',
	'wifi_station_receive_kilobits_per_second' + sta('phy1-ap1', '05') + ' 144100',
	'# HELP wifi_station_transmit_kilobits_per_second Bitrate of the last packet transmitted to the station, in kbit/s.',
	'# TYPE wifi_station_transmit_kilobits_per_second gauge',
	'wifi_station_transmit_kilobits_per_second' + sta('phy0-ap0', '01') + ' 65000',
	'wifi_station_transmit_kilobits_per_second' + sta('phy1-ap1', '03') + ' 288200',
	'wifi_station_transmit_kilobits_per_second' + sta('phy1-ap1', '02') + ' 648500',
	'wifi_station_transmit_kilobits_per_second' + sta('phy1-ap1', '04') + ' 324200',
	'wifi_station_transmit_kilobits_per_second' + sta('phy1-ap1', '05') + ' 432300',
	'# HELP wifi_station_expected_throughput_kilobits_per_second Expected throughput to the station, in kbit/s.',
	'# TYPE wifi_station_expected_throughput_kilobits_per_second gauge',
	'wifi_station_expected_throughput_kilobits_per_second' + sta('phy0-ap0', '01') + ' 58576',
	'wifi_station_expected_throughput_kilobits_per_second' + sta('phy1-ap1', '03') + ' 252360',
	'wifi_station_expected_throughput_kilobits_per_second' + sta('phy1-ap1', '02') + ' 564848',
	'wifi_station_expected_throughput_kilobits_per_second' + sta('phy1-ap1', '04') + ' 283752',
	'wifi_station_expected_throughput_kilobits_per_second' + sta('phy1-ap1', '05') + ' 382872',
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
		ubus: { data: { 'network.wireless:status': {
			radio0: { config: { channel: '36' }, interfaces: [ { ifname: 'wlan0', config: { ssid: 'lab' } } ] },
		} } },
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

describe('collectors.wifi', () => {
	it('exports the radios, networks and stations of the caju AP', () => {
		with_collector(wifi, ap(), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ ...NETWORKS, ...STATIONS ], r.lines);
		});
	});

	it('leaves the stations out with option stations off', () => {
		with_collector(wifi, ap({ options: { stations: '0' } }), (r) => {
			assert.match(true, r.result.ok);
			assert.match(NETWORKS, r.lines);
		});
	});

	it('passes a failed network.wireless status on', () => {
		with_collector(wifi, { ubus: { errors: { 'network.wireless:status': 'Not found' } } }, (r) => {
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
				'wifi_network_info{radio="radio_5G",ifname="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
				'wifi_network_signal_dbm{radio="radio_2G",ifname="phy0-ap0"} -63',
				'wifi_stations_total{radio="radio_5G",ifname="phy1-ap0"} 0',
			]), r.lines);
			assert.match([
				'wifi_network_info{radio="radio_5G",ifname="phy1-ap1",ssid="home",bssid="02:00:00:00:a0:03",mode="Master"} 1',
			], filter(r.lines, (l) => index(l, 'ifname="phy1-ap1"') >= 0));
		});
	});

	it('leaves out a network nl80211 does not know', () => {
		with_collector(wifi, ap({ errors: { 'NL80211_CMD_GET_INTERFACE:phy0-ap0': 'No such device' } }), (r) => {
			assert.match({ error: 'NL80211_FAILED', details: 'phy0-ap0: No such device' },
				{ error: r.result.error, details: r.result.details });
			assert.match([], filter(r.lines, (l) => index(l, 'phy0-ap0') >= 0));
			assert.match(contains([ 'wifi_stations_total{radio="radio_5G",ifname="phy1-ap1"} 4' ]), r.lines);
		});
	});

	it('writes NaN noise, and succeeds, without a channel survey', () => {
		let errors = {};
		for (let dev in IFACES)
			errors[`NL80211_CMD_GET_SURVEY:${dev}`] = 'Operation not supported';

		with_collector(wifi, ap({ errors }), (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([
				'wifi_network_noise_dbm{radio="radio_2G",ifname="phy0-ap0"} NaN',
				'wifi_network_noise_dbm{radio="radio_5G",ifname="phy1-ap1"} NaN',
			]), r.lines);
		});
	});

	it('skips an interface without an ifname, as a radio that is down has', () => {
		let cfg = one_network([], []);
		push(cfg.ubus.data['network.wireless:status'].radio0.interfaces, { section: 'down', config: {} });

		with_collector(wifi, cfg, (r) => {
			assert.match(true, r.result.ok);
			assert.match(1, length(filter(r.lines, (l) => index(l, 'wifi_network_info{') == 0)));
		});
	});

	prop('averages the stations\' signal and bitrate, and counts them',
		gen.array(gen.tuple(gen.int(-95, -20), gen.int(1, 24000)), { min_len: 1, max_len: 12 }), (stations) => {
			let signals = map(stations, (s) => s[0]);
			let bitrates = map(stations, (s) => s[1]);

			with_collector(wifi, one_network(signals, bitrates), (r) => {
				let signal = sample(r.lines, 'wifi_network_signal_dbm');
				let bitrate = sample(r.lines, 'wifi_network_bitrate');
				let quality = sample(r.lines, 'wifi_network_quality');

				assert.match(true, r.result.ok);
				assert.match(length(stations), sample(r.lines, 'wifi_stations_total'));
				assert.match(true, signal >= min(...signals) && signal <= max(...signals), `${signal}`);
				assert.match(true, bitrate >= min(...bitrates) * 100 && bitrate <= max(...bitrates) * 100, `${bitrate}`);
				let error = quality - 100.0 / 70 * (signal + 110);

				assert.match(true, error > -1e-6 && error < 1e-6, `${quality}`);
			});
		});

	it('writes NaN averages for a network without stations', () => {
		with_collector(wifi, one_network([], []), (r) => {
			assert.match(contains([
				'wifi_network_quality{radio="radio0",ifname="wlan0"} NaN',
				'wifi_network_bitrate{radio="radio0",ifname="wlan0"} NaN',
				'wifi_network_noise_dbm{radio="radio0",ifname="wlan0"} -95',
				'wifi_network_signal_dbm{radio="radio0",ifname="wlan0"} NaN',
				'wifi_stations_total{radio="radio0",ifname="wlan0"} 0',
			]), r.lines);
		});
	});
});
