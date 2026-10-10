'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as hostapd_stations from 'prometheus.collectors.hostapd_stations';

// caju-ap: phy0-ap0 has one client, phy1-ap0 none, phy1-ap1 four.
const IFACES = [ 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ];

const UBUS = { 'network.wireless:status': fixtures.ubus('caju-ap', 'network.wireless', 'status') };
for (let dev in IFACES)
	for (let method in [ 'get_status', 'get_clients' ])
		UBUS[`hostapd.${dev}:${method}`] = fixtures.ubus('caju-ap', `hostapd.${dev}`, method);

function ap(data, errors) {
	return { ubus: { data: { ...UBUS, ...(data ?? {}) }, errors: errors ?? {} } };
}

// The labels of a station's series, and of its info, the network's after it.
const AP0 = 'vif="phy0-ap0"';
const AP1 = 'vif="phy1-ap1"';
const NET0 = 'ssid="iot",bssid="02:00:00:00:a0:01",encryption="psk2",frequency="2462",channel="11"';
const NET1 = 'ssid="home",bssid="02:00:00:00:a0:03",encryption="psk2",frequency="5745",channel="149"';

// The clients of phy1-ap1, in get_clients' order.
const CLIENTS1 = [ '05', '04', '02', '03' ];

function family(name, help, type, ap0, ap1) {
	return [
		`# HELP ${name} ${help}`,
		`# TYPE ${name} ${type}`,
		`${name}{${AP0},station="02:00:00:00:00:01"} ${ap0}`,
		...map(CLIENTS1, (mac, i) => `${name}{${AP1},station="02:00:00:00:00:${mac}"} ${ap1[i]}`),
	];
}

const EXPECTED = [
	'# HELP hostapd_station_info A station of an access point, and the network it is on: its SSID, BSSID, encryption, frequency and channel.',
	'# TYPE hostapd_station_info gauge',
	`hostapd_station_info{${AP0},station="02:00:00:00:00:01",${NET0}} 1`,
	...map(CLIENTS1, (mac) => `hostapd_station_info{${AP1},station="02:00:00:00:00:${mac}",${NET1}} 1`),
	...family('hostapd_station_receive_packets_total', 'Packets received from the station.', 'counter',
		354546, [ 10924, 16535, 153553, 15846 ]),
	...family('hostapd_station_receive_bytes_total', 'Bytes received from the station.', 'counter',
		14605645, [ 2422352, 3744045, 48398472, 4873383 ]),
	...family('hostapd_station_transmit_packets_total', 'Packets transmitted to the station.', 'counter',
		47075, [ 72070, 14812, 418763, 14302 ]),
	...family('hostapd_station_transmit_bytes_total', 'Bytes transmitted to the station.', 'counter',
		43747048, [ 103585072, 13015496, 480785238, 9616361 ]),
	...family('hostapd_station_signal_dbm', 'Signal of the station, in dBm.', 'gauge',
		-64, [ -72, -84, -82, -73 ]),
	...family('hostapd_station_flag_auth', 'Whether the station is authenticated.', 'gauge', 1, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_flag_assoc', 'Whether the station is associated.', 'gauge', 1, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_flag_ht', 'Whether the station uses HT (802.11n).', 'gauge', 1, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_flag_vht', 'Whether the station uses VHT (802.11ac).', 'gauge', 0, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_flag_he', 'Whether the station uses HE (802.11ax).', 'gauge', 0, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_flag_mfp', 'Whether the station uses management frame protection.', 'gauge', 0, [ 0, 0, 0, 0 ]),
	...family('hostapd_station_flag_wmm', 'Whether the station uses WMM.', 'gauge', 1, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_vht_capb_su_beamformee', 'Whether the station is a VHT single-user beamformee.', 'gauge',
		0, [ 1, 1, 1, 1 ]),
	...family('hostapd_station_vht_capb_mu_beamformee', 'Whether the station is a VHT multi-user beamformee.', 'gauge',
		0, [ 0, 0, 0, 1 ]),
];

// One radio with interfaces wlan0.. holding `counts` clients each.
function lab(counts) {
	let ifaces = [];
	let data = {};

	for (let i, n in counts) {
		let clients = {};
		for (let j = 0; j < n; j++)
			clients[sprintf('02:00:00:00:%02x:%02x', i, j)] = { auth: true, assoc: true, signal: -40 - j };

		push(ifaces, { ifname: `wlan${i}`, config: { encryption: 'sae' } });
		data[`hostapd.wlan${i}:get_status`] = { ssid: `lab${i}`, bssid: sprintf('02:00:00:00:b0:%02x', i), freq: 5180, channel: 36 };
		data[`hostapd.wlan${i}:get_clients`] = { freq: 5180, clients };
	}

	data['network.wireless:status'] = { radio0: { interfaces: ifaces } };
	return { ubus: { data } };
}

describe('collectors.hostapd_stations', () => {
	it('exports the clients of the caju AP\'s hostapd with the Lua collector\'s labels', () => {
		with_collector(hostapd_stations, ap(), (r) => {
			assert.match(true, r.result.ok);
			assert.match(EXPECTED, r.lines);
		});
	});

	it('writes nothing, and succeeds, without clients', () => {
		let empty = { freq: 5745, clients: {} };

		with_collector(hostapd_stations, ap({ 'hostapd.phy0-ap0:get_clients': empty, 'hostapd.phy1-ap1:get_clients': empty }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('skips an interface hostapd does not serve', () => {
		let data = { ...UBUS };
		delete data['hostapd.phy0-ap0:get_status'];
		delete data['hostapd.phy0-ap0:get_clients'];

		with_collector(hostapd_stations, { ubus: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], filter(r.lines, (l) => index(l, 'phy0-ap0') >= 0));
			assert.match(true, length(r.lines) > 0);
		});
	});

	it('writes the other interfaces when one hostapd does not answer, and fails', () => {
		with_collector(hostapd_stations, ap({}, { 'hostapd.phy1-ap1:get_clients': 'Timed out' }), (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'hostapd.phy1-ap1 get_clients: Timed out' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], filter(r.lines, (l) => index(l, 'phy1-ap1') >= 0));
			assert.match(contains([ `hostapd_station_signal_dbm{${AP0},station="02:00:00:00:00:01"} -64` ]), r.lines);
		});
	});

	it('has nothing to observe without network.wireless, or radios', () => {
		with_collector(hostapd_stations, { ubus: { data: {}, errors: { 'network.wireless:status': "Not found: Failed to resolve object name 'network.wireless'" } } }, (r) => {
			assert.match({ ok: true, none: 'no wireless radios', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_collector(hostapd_stations, { ubus: { data: { 'network.wireless:status': {} } } }, (r) => {
			assert.match({ ok: true, none: 'no wireless radios', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('has nothing to observe where hostapd serves none of the interfaces', () => {
		with_collector(hostapd_stations, { ubus: { data: { 'network.wireless:status': UBUS['network.wireless:status'], 'hostapd:config_add': null } } }, (r) => {
			assert.match({ ok: true, none: 'no hostapd access points', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('passes any other failed network.wireless status on', () => {
		with_collector(hostapd_stations, ap({}, { 'network.wireless:status': 'Request timed out' }), (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('fails when ubus cannot list its objects', () => {
		let cfg = ap();
		cfg.ubus.behavior = { list: () => null };

		with_collector(hostapd_stations, cfg, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	// A 0 would read as a counter reset.
	it('leaves out the counters and the signal a client lacks', () => {
		let client = { auth: true, packets: { rx: 7 }, bytes: { tx: 9 } };

		with_collector(hostapd_stations, ap({ 'hostapd.phy0-ap0:get_clients': { freq: 2462, clients: { '02:00:00:00:00:09': client } }, 'hostapd.phy1-ap1:get_clients': { clients: {} } }), (r) => {
			let station = `{${AP0},station="02:00:00:00:00:09"}`;

			assert.match(true, r.result.ok);
			assert.match([
				`hostapd_station_receive_packets_total${station} 7`,
				`hostapd_station_transmit_bytes_total${station} 9`,
			], filter(r.lines, (l) => match(l, /^hostapd_station_[a-z_]+_total\{/)));
			assert.match(contains([
				`hostapd_station_flag_auth${station} 1`,
				`hostapd_station_flag_assoc${station} 0`,
			]), r.lines);
			assert.match([], filter(r.lines, (l) => index(l, 'hostapd_station_signal_dbm{') == 0));
		});
	});

	// hostapd sends the packet counts with blobmsg_add_u32(), which ucode's ubus gives signed.
	it('reads packet counts past 2^31 unsigned, as hostapd sent them', () => {
		let client = { auth: true, packets: { rx: -1, tx: -2147483648 }, bytes: { rx: 5000000000, tx: 1 } };

		with_collector(hostapd_stations, ap({ 'hostapd.phy0-ap0:get_clients': { clients: { '02:00:00:00:00:09': client } }, 'hostapd.phy1-ap1:get_clients': { clients: {} } }), (r) => {
			let station = `{${AP0},station="02:00:00:00:00:09"}`;

			assert.match(contains([
				`hostapd_station_receive_packets_total${station} 4294967295`,
				`hostapd_station_receive_bytes_total${station} 5000000000`,
				`hostapd_station_transmit_packets_total${station} 2147483648`,
			]), r.lines);
		});
	});

	it('labels a station\'s series by its interface and MAC alone, so a channel change starts none anew', () => {
		let moved = { ...UBUS['hostapd.phy1-ap1:get_status'], freq: 5260, channel: 52 };

		with_collector(hostapd_stations, ap({ 'hostapd.phy1-ap1:get_status': moved }), (r) => {
			let station = `{${AP1},station="02:00:00:00:00:05"}`;

			assert.match(contains([
				`hostapd_station_info{${AP1},station="02:00:00:00:00:05",ssid="home",bssid="02:00:00:00:a0:03",encryption="psk2",frequency="5260",channel="52"} 1`,
				`hostapd_station_receive_bytes_total${station} 2422352`,
			]), r.lines);
			assert.match([], filter(r.lines, (l) => index(l, 'channel=') >= 0 && index(l, 'hostapd_station_info{') != 0));
		});
	});

	prop('writes one sample per client for each interface',
		gen.array(gen.int(0, 8), { min_len: 1, max_len: 4 }), (counts) => {
			with_collector(hostapd_stations, lab(counts), (r) => {
				assert.match(true, r.result.ok);

				for (let i, n in counts) {
					let lines = filter(r.lines, (l) => index(l, `hostapd_station_flag_auth{vif="wlan${i}",`) == 0);
					assert.match(n, length(lines));
				}
			});
		});
});
