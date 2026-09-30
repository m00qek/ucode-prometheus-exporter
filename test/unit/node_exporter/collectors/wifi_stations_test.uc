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
	return `{ifname="${dev}",mac="02:00:00:00:00:${mac}"}`;
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
	'# HELP wifi_stations Stations associated with the interface.',
	'# TYPE wifi_stations gauge',
	'wifi_stations{ifname="phy0-ap0"} 1',
	'wifi_stations{ifname="phy1-ap0"} 0',
	'wifi_stations{ifname="phy1-ap1"} 4',
	...per_station('wifi_station_signal_dbm', 'Signal of the station, in dBm.', 'gauge',
		-63, [ -73, -81, -84, -72 ]),
	...per_station('wifi_station_inactive_milliseconds', 'Time since the station was last active, in milliseconds.', 'gauge',
		10, [ 23310, 140, 37500, 15200 ]),
	...per_station('wifi_station_expected_throughput_kilobits_per_second', 'Expected throughput to the station, in kbit/s.', 'gauge',
		58576, [ 252360, 564848, 283752, 382872 ]),
	...per_station('wifi_station_transmit_kilobits_per_second', 'Bitrate of the last packet transmitted to the station, in kbit/s.', 'gauge',
		65000, [ 288200, 648500, 324200, 432300 ]),
	...per_station('wifi_station_receive_kilobits_per_second', 'Bitrate of the last packet received from the station, in kbit/s.', 'gauge',
		72200, [ 432300, 144100, 8100, 144100 ]),
	...per_station('wifi_station_transmit_packets_total', 'Packets transmitted to the station.', 'counter',
		47105, [ 14302, 418802, 14812, 72070 ]),
	...per_station('wifi_station_receive_packets_total', 'Packets received from the station.', 'counter',
		354610, [ 15846, 153592, 16535, 10924 ]),
	...per_station('wifi_station_transmit_bytes_total', 'Bytes transmitted to the station.', 'counter',
		43766742, [ 9616361, 480803379, 13015496, 103585072 ]),
	...per_station('wifi_station_receive_bytes_total', 'Bytes received from the station.', 'counter',
		14613247, [ 4873383, 48422804, 3744045, 2422352 ]),
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
	it('exports the stations of the caju AP as the Lua collector did', () => {
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
				'wifi_stations{ifname="wlan0"} 1',
				'wifi_stations{ifname="wlan1"} 0',
				'wifi_station_inactive_milliseconds{ifname="wlan0",mac="02:00:00:00:00:01"} 0',
				'wifi_station_transmit_packets_total{ifname="wlan0",mac="02:00:00:00:00:01"} 0',
				'wifi_station_receive_packets_total{ifname="wlan0",mac="02:00:00:00:00:01"} 0',
				'wifi_station_transmit_bytes_total{ifname="wlan0",mac="02:00:00:00:00:01"} 7',
				'wifi_station_receive_bytes_total{ifname="wlan0",mac="02:00:00:00:00:01"} 9',
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
			assert.match(contains([ 'wifi_stations{ifname="phy1-ap0"} 0', 'wifi_stations{ifname="phy1-ap1"} 4' ]), r.lines);
		});
	});

	prop('counts each interface\'s stations, one sample each',
		gen.tuple(gen.int(0, 20), gen.int(0, 20)), (counts) => {
			with_collector(wifi_stations, lab(counts), (r) => {
				assert.match(true, r.result.ok);
				assert.match(contains([
					`wifi_stations{ifname="wlan0"} ${counts[0]}`,
					`wifi_stations{ifname="wlan1"} ${counts[1]}`,
				]), r.lines);
				assert.match(counts[0] + counts[1],
					length(filter(r.lines, (l) => index(l, 'wifi_station_signal_dbm{') == 0)));
			});
		});
});
