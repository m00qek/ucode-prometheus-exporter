'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as hostapd_ubus_stations from 'prometheus.collectors.hostapd_ubus_stations';

// caju-ap's hostapd objects, and the two other objects hostapd publishes there,
// which are not access points. None of its clients announces RRM.
const UBUS = {
	'hostapd:config_add': null,
	'hostapd-auth:reload': null,
};
for (let dev in [ 'phy0-ap0', 'phy1-ap0', 'phy1-ap1' ])
	UBUS[`hostapd.${dev}:get_clients`] = fixtures.ubus('caju-ap', `hostapd.${dev}`, 'get_clients');

const FAMILIES = [
	[ 'link_measurement', 'link measurement' ],
	[ 'neighbor_report', 'neighbor report' ],
	[ 'beacon_report_passive', 'passive beacon report' ],
	[ 'beacon_report_active', 'active beacon report' ],
	[ 'beacon_report_table', 'beacon table report' ],
	[ 'lci_measurement', 'LCI measurement' ],
	[ 'ftm_range_report', 'FTM range report' ],
];

const STATIONS = [
	'ifname="phy0-ap0",freq="2462",station="02:00:00:00:00:01"',
	'ifname="phy1-ap1",freq="5745",station="02:00:00:00:00:05"',
	'ifname="phy1-ap1",freq="5745",station="02:00:00:00:00:04"',
	'ifname="phy1-ap1",freq="5745",station="02:00:00:00:00:02"',
	'ifname="phy1-ap1",freq="5745",station="02:00:00:00:00:03"',
];

let EXPECTED = [];
for (let f in FAMILIES) {
	let name = `hostapd_ubus_station_rrm_caps_${f[0]}`;

	push(EXPECTED, `# HELP ${name} Whether the station supports ${f[1]}.`, `# TYPE ${name} gauge`,
		...map(STATIONS, (s) => `${name}{${s}} 0`));
}

function one_client(client) {
	return { ubus: { data: { 'hostapd.wlan0:get_clients': { freq: 5180, clients: { '02:00:00:00:00:01': client } } } } };
}

// The value of each family for the one client, in FAMILIES order.
function values(lines) {
	let v = [];

	for (let f in FAMILIES)
		for (let l in lines)
			if (index(l, `hostapd_ubus_station_rrm_caps_${f[0]}{`) == 0)
				push(v, +split(l, ' ')[1]);

	return v;
}

describe('collectors.hostapd_ubus_stations', () => {
	it('exports the RRM capabilities of the caju AP\'s clients', () => {
		with_collector(hostapd_ubus_stations, { ubus: { data: UBUS } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(EXPECTED, r.lines);
		});
	});

	it('reads each capability from its octet and bit', () => {
		with_collector(hostapd_ubus_stations, one_client({ rrm: [ 0x73, 0x10, 0, 0, 0x04 ] }), (r) => {
			assert.match([ 1, 1, 1, 1, 1, 1, 1 ], values(r.lines));
		});

		with_collector(hostapd_ubus_stations, one_client({ rrm: [ 0x8c, 0xef, 0xff, 0xff, 0xfb ] }), (r) => {
			assert.match([ 0, 0, 0, 0, 0, 0, 0 ], values(r.lines));
		});
	});

	prop('sets a family exactly when its bit is set',
		gen.array(gen.int(0, 255), { len: 5 }), (rrm) => {
			with_collector(hostapd_ubus_stations, one_client({ rrm }), (r) => {
				let bit = (octet, n) => (rrm[octet] >> n) & 1;

				assert.match(true, r.result.ok);
				assert.match([ bit(0, 0), bit(0, 1), bit(0, 4), bit(0, 5), bit(0, 6), bit(1, 4), bit(4, 2) ], values(r.lines));
			});
		});

	it('leaves out a client without an rrm array', () => {
		with_collector(hostapd_ubus_stations, one_client({ auth: true }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('skips a hostapd object without get_clients, as a wired port has', () => {
		let errors = { 'hostapd.eth0:get_clients': "Method not found: Failed to invoke function 'get_clients' on object 'hostapd.eth0'" };

		with_collector(hostapd_ubus_stations, { ubus: { data: { ...UBUS, 'hostapd.eth0:get_status': {} }, errors } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(EXPECTED, r.lines);
		});
	});

	it('writes the other interfaces when one hostapd does not answer, and fails', () => {
		with_collector(hostapd_ubus_stations, { ubus: { data: UBUS, errors: { 'hostapd.phy0-ap0:get_clients': 'Timed out' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'hostapd.phy0-ap0 get_clients: Timed out' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], filter(r.lines, (l) => index(l, 'phy0-ap0') >= 0));
			assert.match(contains([ `hostapd_ubus_station_rrm_caps_link_measurement{${STATIONS[1]}} 0` ]), r.lines);
		});
	});

	it('has nothing to observe without a hostapd object, as without radios', () => {
		with_collector(hostapd_ubus_stations, { ubus: { data: { 'system:board': {}, 'hostapd:config_add': null } } }, (r) => {
			assert.match({ ok: true, none: 'no hostapd access points', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('observes hostapd without clients: families without samples', () => {
		with_collector(hostapd_ubus_stations, { ubus: { data: { 'hostapd.phy0-ap0:get_clients': { freq: 2462, clients: {} } } } }, (r) => {
			assert.match([ true, null, [] ], [ r.result.ok, r.result.none, r.lines ]);
		});
	});

	it('fails when ubus cannot list its objects', () => {
		with_collector(hostapd_ubus_stations, { ubus: { data: UBUS, behavior: { list: () => null } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED' }, { ok: r.result.ok, error: r.result.error });
		});
	});
});
