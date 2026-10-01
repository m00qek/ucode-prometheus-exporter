'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as wifi_stations from 'node_exporter.collectors.wifi_stations';

// caju-ap: phy0-ap0 has one station, phy1-ap0 none (an empty dump is a null
// reply), phy1-ap1 four.
const IFACES = [ 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ];

const WIRELESS = fixtures.ubus('caju-ap', 'network.wireless', 'status');
const DUMPS = {};
for (let dev in IFACES)
	DUMPS[`NL80211_CMD_GET_STATION:${dev}`] =
		json(fixtures.file('caju-ap', `/nl80211/NL80211_CMD_GET_STATION.${dev}.json`));

function ap(errors) {
	return {
		ubus: { data: { 'network.wireless:status': WIRELESS } },
		nl80211: { data: DUMPS, errors: errors ?? {} },
	};
}

function sta(dev, mac) {
	return `{device="${dev}",mac_address="02:00:00:00:00:${mac}"}`;
}

// The stations of phy1-ap1, in dump order.
const AP1 = [ '03', '02', '04', '05' ];

function per_station(name, help, type, ap0, ap1) {
	return [
		`# HELP ${name} ${help}`,
		`# TYPE ${name} ${type}`,
		name + sta('phy0-ap0', '01') + ' ' + ap0,
		...map(AP1, (mac, i) => name + sta('phy1-ap1', mac) + ' ' + ap1[i]),
	];
}

const EXPECTED = [
	'# HELP node_wifi_stations Stations associated with the interface.',
	'# TYPE node_wifi_stations gauge',
	'node_wifi_stations{device="phy0-ap0"} 1',
	'node_wifi_stations{device="phy1-ap0"} 0',
	'node_wifi_stations{device="phy1-ap1"} 4',
	...per_station('node_wifi_station_connected_seconds_total', 'The total number of seconds a station has been connected to an access point.', 'counter',
		12053, [ 12024, 8628, 5271, 5265 ]),
	...per_station('node_wifi_station_inactive_seconds', 'The number of seconds since any wireless activity has occurred on a station.', 'gauge',
		0.01, [ 23.31, 0.14, 37.5, 15.2 ]),
	...per_station('node_wifi_station_receive_bits_per_second', 'The current WiFi receive bitrate of a station, in bits per second.', 'gauge',
		72200000, [ 432300000, 144100000, 8100000, 144100000 ]),
	...per_station('node_wifi_station_transmit_bits_per_second', 'The current WiFi transmit bitrate of a station, in bits per second.', 'gauge',
		65000000, [ 288200000, 648500000, 324200000, 432300000 ]),
	...per_station('node_wifi_station_receive_bytes_total', 'The total number of bytes received by a WiFi station.', 'counter',
		14613247, [ 4873383, 48422804, 3744045, 2422352 ]),
	...per_station('node_wifi_station_transmit_bytes_total', 'The total number of bytes transmitted by a WiFi station.', 'counter',
		43766742, [ 9616361, 480803379, 13015496, 103585072 ]),
	...per_station('node_wifi_station_signal_dbm', 'The current WiFi signal strength, in decibel-milliwatts (dBm).', 'gauge',
		-63, [ -73, -81, -84, -72 ]),
	...per_station('node_wifi_station_transmit_retries_total', 'The total number of times a station has had to retry while sending a packet.', 'counter',
		11791, [ 3375, 22470, 1219, 5603 ]),
	...per_station('node_wifi_station_transmit_failed_total', 'The total number of times a station has failed to send a packet.', 'counter',
		11813, [ 3376, 22470, 1219, 5603 ]),
	...per_station('node_wifi_station_transmitted_packets_total', 'The total number of packets transmitted by a station.', 'counter',
		47105, [ 14302, 418802, 14812, 72070 ]),
	...per_station('node_wifi_station_received_packets_total', 'The total number of packets received by a station.', 'counter',
		354610, [ 15846, 153592, 16535, 10924 ]),
	...per_station('node_wifi_station_expected_throughput_bits_per_second', 'Expected throughput to the station, in bits per second.', 'gauge',
		58576000, [ 252360000, 564848000, 283752000, 382872000 ]),
];

// Two radios, an interface each, with dumps of `counts` stations.
function lab(counts) {
	let data = {};

	for (let i, n in counts) {
		let dump = [];
		for (let j = 0; j < n; j++)
			push(dump, { mac: sprintf('02:00:00:00:%02x:%02x', i, j), sta_info: { signal: -50, inactive_time: j } });
		data[`NL80211_CMD_GET_STATION:wlan${i}`] = n ? dump : null;
	}

	return {
		ubus: { data: { 'network.wireless:status': {
			radio0: { interfaces: [ { ifname: 'wlan0' } ] },
			radio1: { interfaces: [ { ifname: 'wlan1' } ] },
		} } },
		nl80211: { data },
	};
}

describe('collectors.wifi_stations', () => {
	it('exports the stations of the caju AP, named as node_exporter names them', () => {
		with_collector(wifi_stations, ap(), (r) => {
			assert.match(true, r.result.ok);
			assert.match(EXPECTED, r.lines);
		});
	});

	it('leaves out what the driver reports as 0, as iwinfo did', () => {
		let cfg = lab([ 0, 0 ]);
		cfg.nl80211.data['NL80211_CMD_GET_STATION:wlan0'] = [ {
			mac: '02:00:00:00:00:01',
			sta_info: {
				signal: 0, inactive_time: 0, expected_throughput: 0,
				tx_bitrate: { bitrate32: 0 }, rx_bitrate: {},
				tx_packets: 0, rx_packets: 0, tx_bytes: 7, rx_bytes: 9,
			},
		} ];

		with_collector(wifi_stations, cfg, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_wifi_stations{device="wlan0"} 1',
				'node_wifi_stations{device="wlan1"} 0',
				'node_wifi_station_inactive_seconds{device="wlan0",mac_address="02:00:00:00:00:01"} 0',
				'node_wifi_station_receive_bytes_total{device="wlan0",mac_address="02:00:00:00:00:01"} 9',
				'node_wifi_station_transmit_bytes_total{device="wlan0",mac_address="02:00:00:00:00:01"} 7',
				'node_wifi_station_transmitted_packets_total{device="wlan0",mac_address="02:00:00:00:00:01"} 0',
				'node_wifi_station_received_packets_total{device="wlan0",mac_address="02:00:00:00:00:01"} 0',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('passes a failed network.wireless status on', () => {
		with_collector(wifi_stations, { ubus: { errors: { 'network.wireless:status': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('fails with NEED_MISSING without ucode-mod-nl80211', () => {
		with_collector(wifi_stations, { ...ap(), no_nl80211: true }, (r) => {
			assert.match({ ok: false, error: 'NEED_MISSING' }, { ok: r.result.ok, error: r.result.error });
		});
	});

	it('writes the other interfaces when a dump fails, and fails', () => {
		with_collector(wifi_stations, ap({ 'NL80211_CMD_GET_STATION:phy0-ap0': 'No such device' }), (r) => {
			assert.match({ ok: false, error: 'NL80211_FAILED', details: 'phy0-ap0: No such device' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], filter(r.lines, (l) => index(l, 'phy0-ap0') >= 0));
			assert.match(contains([ 'node_wifi_stations{device="phy1-ap0"} 0', 'node_wifi_stations{device="phy1-ap1"} 4' ]), r.lines);
		});
	});

	prop('counts each interface\'s stations, one sample each',
		gen.tuple(gen.int(0, 20), gen.int(0, 20)), (counts) => {
			with_collector(wifi_stations, lab(counts), (r) => {
				assert.match(true, r.result.ok);
				assert.match(contains([
					`node_wifi_stations{device="wlan0"} ${counts[0]}`,
					`node_wifi_stations{device="wlan1"} ${counts[1]}`,
				]), r.lines);
				assert.match(counts[0] + counts[1],
					length(filter(r.lines, (l) => index(l, 'node_wifi_station_signal_dbm{') == 0)));
			});
		});

	prop('gives the inactive time in seconds and the rates in bits per second',
		gen.tuple(gen.int(0, 10000000), gen.int(1, 50000), gen.int(1, 5000000)), (x) => {
			let cfg = lab([ 0, 0 ]);
			cfg.nl80211.data['NL80211_CMD_GET_STATION:wlan0'] = [ { mac: '02:00:00:00:00:01', sta_info: {
				inactive_time: x[0], tx_bitrate: { bitrate32: x[1] }, expected_throughput: x[2],
			} } ];

			with_collector(wifi_stations, cfg, (r) => {
				let labels = '{device="wlan0",mac_address="02:00:00:00:00:01"}';

				assert.match(true, r.result.ok);
				assert.match(contains([
					`node_wifi_station_inactive_seconds${labels} ${x[0] / 1000.0}`,
					`node_wifi_station_transmit_bits_per_second${labels} ${x[1] * 100000}`,
					`node_wifi_station_expected_throughput_bits_per_second${labels} ${x[2] * 1000}`,
				]), r.lines);
			});
		});
});
