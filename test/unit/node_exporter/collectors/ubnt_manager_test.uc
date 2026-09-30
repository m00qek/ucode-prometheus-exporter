'use strict';

import { describe, it, assert, contains } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as commands from 'lib.commands';
import * as ubnt_manager from 'node_exporter.collectors.ubnt_manager';

// No Ubiquiti radio here. ubnt-manager (feeds/packages utils/ubnt-manager) lists
// the devices of /etc/config/ubnt-manager with -l, and with -j -t prints what
// /usr/www/status.cgi answers over ssh, the Content-Type line blanked by sed.
// The two status.cgi replies below follow airOS 8 (LiteBeam 5AC Gen2) and
// airOS 6 (NanoStation loco M5) with the fields the Lua collector read; names,
// addresses and values are made up.
const AIROS8 = '\n\n' + fixtures.file('synthetic', '/commands/ubnt-manager-j-t-litebeam.json');
const AIROS6 = '\n\n' + fixtures.file('synthetic', '/commands/ubnt-manager-j-t-nsloco.json');

const LIST = commands.line([ 'ubnt-manager', '-l' ]);

function status(device) {
	return commands.line([ 'ubnt-manager', '-j', '-t', device ]);
}

function run(o, cb) {
	with_collector(ubnt_manager, { fs: commands.fs(o) }, cb);
}

function family(name, mtype, help, sample) {
	return [ `# HELP ${name} ${help}`, `# TYPE ${name} ${mtype}`, sample ];
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.ubnt_manager', () => {
	it('exports an airOS 8 radio', () => {
		run({ [LIST]: { out: ' litebeam\n' }, [status('litebeam')]: { out: AIROS8 } }, (r) => {
			let d = '{device="litebeam"}';

			assert.match(true, r.result.ok);
			assert.match([
				...family('ubnt_uptime', 'counter', 'Seconds since the radio booted.',
					'ubnt_uptime{device="litebeam",hostname="link-north",devmodel="LiteBeam 5AC Gen2",fwversion="v8.7.11",essid="backhaul"} 1209617'),
				...family('ubnt_loadavg', 'gauge', 'Load average of the radio.', `ubnt_loadavg${d} 0.070312`),
				...family('ubnt_totalram', 'gauge', 'Total memory of the radio.', `ubnt_totalram${d} 63012864`),
				...family('ubnt_freeram', 'gauge', 'Free memory of the radio.', `ubnt_freeram${d} 14909440`),
				...family('ubnt_temperature', 'gauge', 'Temperature of the radio.', `ubnt_temperature${d} 0`),
				...family('ubnt_cpuload', 'gauge', 'CPU load of the radio, in percent.', `ubnt_cpuload${d} 7.920792`),
				...family('ubnt_timestamp', 'counter', 'Unix time on the radio.', `ubnt_timestamp${d} 1790856000`),
				...family('ubnt_band', 'gauge', 'The wireless band.', `ubnt_band${d} 2`),
				...family('ubnt_frequency', 'gauge', 'The wireless frequency, in MHz.', `ubnt_frequency${d} 5540`),
				...family('ubnt_center1_freq', 'gauge', 'Center frequency of the channel, in MHz.', `ubnt_center1_freq${d} 5550`),
				...family('ubnt_dfs', 'gauge', 'Whether the channel needs DFS.', `ubnt_dfs${d} 1`),
				...family('ubnt_distance', 'gauge', 'Link distance, in meters.', `ubnt_distance${d} 1350`),
				...family('ubnt_noisef', 'gauge', 'Noise floor, in dBm.', `ubnt_noisef${d} -94`),
				...family('ubnt_txpower', 'gauge', 'Transmit power, in dBm.', `ubnt_txpower${d} 16`),
				...family('ubnt_aprepeater', 'gauge', 'Whether the radio is an AP repeater.', `ubnt_aprepeater${d} 0`),
				...family('ubnt_rstatus', 'gauge', 'Radio status.', `ubnt_rstatus${d} 5`),
				...family('ubnt_chanbw', 'gauge', 'Channel width, in MHz.', `ubnt_chanbw${d} 40`),
				...family('ubnt_rx_chainmask', 'gauge', 'Receive chain mask.', `ubnt_rx_chainmask${d} 3`),
				...family('ubnt_tx_chainmask', 'gauge', 'Transmit chain mask.', `ubnt_tx_chainmask${d} 3`),
				...family('ubnt_cac_state', 'gauge', 'DFS channel availability check state.', `ubnt_cac_state${d} 0`),
				...family('ubnt_cac_timeout', 'gauge', 'DFS channel availability check timeout.', `ubnt_cac_timeout${d} 0`),
				...family('ubnt_rx_idx', 'gauge', 'Receive modulation index.', `ubnt_rx_idx${d} 8`),
				...family('ubnt_rx_nss', 'gauge', 'Receive spatial streams.', `ubnt_rx_nss${d} 2`),
				...family('ubnt_tx_idx', 'gauge', 'Transmit modulation index.', `ubnt_tx_idx${d} 9`),
				...family('ubnt_tx_nss', 'gauge', 'Transmit spatial streams.', `ubnt_tx_nss${d} 2`),
				...family('ubnt_count', 'gauge', 'Stations associated.', `ubnt_count${d} 1`),
				...family('ubnt_throughput_tx', 'gauge', 'Transmit throughput, in kbit/s.', `ubnt_throughput_tx${d} 1843`),
				...family('ubnt_throughput_rx', 'gauge', 'Receive throughput, in kbit/s.', `ubnt_throughput_rx${d} 20512`),
				...family('ubnt_polling_cb_capacity', 'gauge', 'airMAX combined capacity, in kbit/s.', `ubnt_polling_cb_capacity${d} 331140`),
				...family('ubnt_polling_dl_capacity', 'gauge', 'airMAX download capacity, in kbit/s.', `ubnt_polling_dl_capacity${d} 297720`),
				...family('ubnt_polling_ul_capacity', 'gauge', 'airMAX upload capacity, in kbit/s.', `ubnt_polling_ul_capacity${d} 253920`),
				...family('ubnt_use', 'gauge', 'airtime use, in percent.', `ubnt_use${d} 17`),
				...family('ubnt_tx_use', 'gauge', 'Transmit airtime use, in percent.', `ubnt_tx_use${d} 8`),
				...family('ubnt_rx_use', 'gauge', 'Receive airtime use, in percent.', `ubnt_rx_use${d} 9`),
				...family('ubnt_atpc_status', 'gauge', 'Automatic transmit power control status.', `ubnt_atpc_status${d} 2`),
			], r.lines);
		});
	});

	it('exports an airOS 6 radio, its frequency read from "5745 MHz"', () => {
		run({ [LIST]: { out: 'nsloco\n' }, [status('nsloco')]: { out: AIROS6 } }, (r) => {
			let d = '{device="nsloco"}';

			assert.match(true, r.result.ok);
			assert.match([
				...family('ubnt_uptime', 'counter', 'Seconds since the radio booted.',
					'ubnt_uptime{device="nsloco",hostname="link-south",devmodel="NanoStation loco M5",fwversion="XW.v6.3.6",essid="backhaul"} 532104'),
				...family('ubnt_totalram', 'gauge', 'Total memory of the radio.', `ubnt_totalram${d} 61120`),
				...family('ubnt_freeram', 'gauge', 'Free memory of the radio.', `ubnt_freeram${d} 20140`),
				...family('ubnt_cpuload', 'gauge', 'CPU load of the radio, in percent.', `ubnt_cpuload${d} 14`),
				...family('ubnt_cpubusy', 'gauge', 'Busy CPU time of the radio.', `ubnt_cpubusy${d} 3521`),
				...family('ubnt_cputotal', 'gauge', 'Total CPU time of the radio.', `ubnt_cputotal${d} 25150`),
				...family('ubnt_channel', 'gauge', 'The wireless channel.', `ubnt_channel${d} 149`),
				...family('ubnt_frequency', 'gauge', 'The wireless frequency, in MHz.', `ubnt_frequency${d} 5745`),
				...family('ubnt_dfs', 'gauge', 'Whether the channel needs DFS.', `ubnt_dfs${d} 0`),
				...family('ubnt_signal', 'gauge', 'Signal strength, in dBm.', `ubnt_signal${d} -62`),
				...family('ubnt_rssi', 'gauge', 'Received signal strength indicator.', `ubnt_rssi${d} 34`),
				...family('ubnt_noisef', 'gauge', 'Noise floor, in dBm.', `ubnt_noisef${d} -96`),
				...family('ubnt_txpower', 'gauge', 'Transmit power, in dBm.', `ubnt_txpower${d} 20`),
				...family('ubnt_distance', 'gauge', 'Link distance, in meters.', `ubnt_distance${d} 1200`),
				...family('ubnt_txrate', 'gauge', 'Transmit rate, in Mbit/s.', `ubnt_txrate${d} 150`),
				...family('ubnt_rxrate', 'gauge', 'Receive rate, in Mbit/s.', `ubnt_rxrate${d} 135`),
				...family('ubnt_count', 'gauge', 'Stations associated.', `ubnt_count${d} 1`),
			], r.lines);
		});
	});

	it('exports every listed radio in one family per metric', () => {
		run({
			[LIST]: { out: ' litebeam nsloco\n' },
			[status('litebeam')]: { out: AIROS8 },
			[status('nsloco')]: { out: AIROS6 },
		}, (r) => {
			assert.match(true, r.result.ok);
			assert.match(contains([
				'# TYPE ubnt_frequency gauge',
				'ubnt_frequency{device="litebeam"} 5540',
				'ubnt_frequency{device="nsloco"} 5745',
			]), r.lines);
		});
	});

	it('exports nothing when no device is configured', () => {
		run({ [LIST]: { out: ' \n' } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('skips a radio whose status has no host or wireless, or whose airOS it does not know', () => {
		run({
			[LIST]: { out: 'down old\n' },
			[status('down')]: { out: '\n\n' },
			[status('old')]: { out: '{"host":{"fwversion":"XM.v5.6.15"},"wireless":{}}' },
		}, (r) => {
			// ubnt-manager prints nothing when ssh fails, which is no JSON.
			assert.match({ ok: false, error: 'SOURCE_INVALID' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});

		run({
			[LIST]: { out: 'bare old\n' },
			[status('bare')]: { out: '{"host":{"fwversion":"v8.7.11"}}' },
			[status('old')]: { out: '{"host":{"fwversion":"XM.v5.6.15"},"wireless":{}}' },
		}, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('keeps the other radios when one fails', () => {
		run({
			[LIST]: { out: 'gone nsloco\n' },
			[status('gone')]: { out: '', status: 255 },
			[status('nsloco')]: { out: AIROS6 },
		}, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED', details: 'ubnt-manager: exit status 255' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match(contains([ 'ubnt_channel{device="nsloco"} 149' ]), samples(r.lines));
		});
	});

	it('fails with COMMAND_FAILED when ubnt-manager cannot list the devices', () => {
		run({ [LIST]: { out: '', status: 1 } }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});
});
