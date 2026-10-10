'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import { rc } from 'prometheus.exporter.devkit.rc';
import * as fixtures from 'lib.fixtures';
import * as dawn from 'prometheus.collectors.dawn';

// No device here runs DAWN: this reply is laid out as DAWN's
// build_network_overview() (src/utils/ubus.c) writes it. This node serves
// 02:00:00:00:A0:03 ("home") and 02:00:00:00:A0:01 ("iot"); 02:00:00:00:B0:01
// is a neighbour's. Client 02:00:00:00:00:05 has not been heard (no signal).
const NETWORK = fixtures.ubus('synthetic', 'dawn', 'get_network');

const HOME = 'ssid="home",bssid="02:00:00:00:A0:03",freq="5745",hostname="ap-hall",ht_support="1",vht_support="1",' +
	'neighbor_report="02000000a0038f090000809509"';
const IOT = 'ssid="iot",bssid="02:00:00:00:A0:01",freq="2462",hostname="ap-hall",ht_support="1",vht_support="0",' +
	'neighbor_report="02000000a0018f090000510b07"';

function network(reply) {
	return { ubus: { data: { 'dawn:get_network': reply } } };
}

describe('collectors.dawn', () => {
	it('exports this node\'s access points and their clients', () => {
		with_collector(dawn, network(NETWORK), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP dawn_ap_channel_utilization_ratio Channel utilization of the access point, from 0 to 1.',
				'# TYPE dawn_ap_channel_utilization_ratio gauge',
				`dawn_ap_channel_utilization_ratio{${HOME}} 0.06666666666666667`,
				`dawn_ap_channel_utilization_ratio{${IOT}} 0.6627450980392157`,
				'# HELP dawn_ap_stations Stations associated with the access point.',
				'# TYPE dawn_ap_stations gauge',
				`dawn_ap_stations{${HOME}} 2`,
				`dawn_ap_stations{${IOT}} 1`,
				'# HELP dawn_station_signal_dbm Signal of the station, in dBm; -255 when DAWN has not heard it.',
				'# TYPE dawn_station_signal_dbm gauge',
				'dawn_station_signal_dbm{ssid="home",bssid="02:00:00:00:A0:03",mac="02:00:00:00:00:02",ht_support="1",vht_support="1"} -81',
				'dawn_station_signal_dbm{ssid="home",bssid="02:00:00:00:A0:03",mac="02:00:00:00:00:05",ht_support="1",vht_support="1"} -255',
				'dawn_station_signal_dbm{ssid="iot",bssid="02:00:00:00:A0:01",mac="02:00:00:00:00:01",ht_support="1",vht_support="0"} -64',
			], r.lines);
		});
	});

	it('writes nothing, and succeeds, for a network without local access points', () => {
		with_collector(dawn, network({ home: { '02:00:00:00:B0:01': NETWORK.home['02:00:00:00:B0:01'] } }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('passes a failed call on when DAWN is enabled and not running', () => {
		with_collector(dawn, { ubus: { data: rc({ dawn: true }), errors: { 'dawn:get_network': 'Not found' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'dawn get_network: Not found' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('has nothing to observe where DAWN is disabled, or not installed', () => {
		with_collector(dawn, { ubus: { data: rc({ dawn: false }), errors: { 'dawn:get_network': 'Not found' } } }, (r) => {
			assert.match({ ok: true, none: 'dawn is disabled', error: null, lines: [], logs: [] }, outcome(r));
		});
		with_collector(dawn, { ubus: { data: rc({}), errors: { 'dawn:get_network': 'Not found' } } }, (r) => {
			assert.match({ ok: true, none: 'dawn is not installed', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('fails with SOURCE_INVALID for a reply that is not an object', () => {
		with_collector(dawn, network([]), (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	prop('writes the utilization as a ratio of 255, and a signal per client',
		gen.tuple(gen.int(0, 255), gen.int(0, 12)), (x) => {
			let ap = { freq: 5180, channel_utilization: x[0], num_sta: x[1], local: true };
			for (let i = 0; i < x[1]; i++)
				ap[sprintf('02:00:00:00:01:%02X', i)] = { signal: -40 - i };

			with_collector(dawn, network({ lab: { '02:00:00:00:B0:02': ap } }), (r) => {
				let ratio = +split(filter(r.lines, (l) => index(l, 'dawn_ap_channel_utilization_ratio{') == 0)[0], ' ')[1];
				let error = ratio - x[0] / 255.0;

				assert.match(true, r.result.ok);
				assert.match(true, ratio >= 0 && ratio <= 1 && error > -1e-9 && error < 1e-9, `${ratio}`);
				assert.match(x[1], length(filter(r.lines, (l) => index(l, 'dawn_station_signal_dbm{') == 0)));
			});
		});
});
