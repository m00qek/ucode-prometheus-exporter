'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { with_collector, jail_of, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as commands from 'prometheus.exporter.devkit.commands';
import * as ubnt_manager from 'prometheus.collectors.ubnt_manager';
import { format_value } from 'prometheus.exporter.exposition';

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
	it('exports an airOS 8 radio, in base units', () => {
		run({ [LIST]: { out: ' litebeam\n' }, [status('litebeam')]: { out: AIROS8 } }, (r) => {
			let d = '{device="litebeam"}';

			assert.match(true, r.result.ok);
			assert.match([
				...family('ubnt_info', 'gauge', 'The radio, by its names and firmware.',
					'ubnt_info{device="litebeam",hostname="link-north",devmodel="LiteBeam 5AC Gen2",fwversion="v8.7.11",essid="backhaul"} 1'),
				...family('ubnt_uptime_seconds', 'gauge', 'Seconds since the radio booted.', `ubnt_uptime_seconds${d} 1209617`),
				...family('ubnt_loadavg', 'gauge', 'Load average of the radio.', `ubnt_loadavg${d} 0.070312`),
				...family('ubnt_memory_total_bytes', 'gauge', 'Total memory of the radio, in bytes.', `ubnt_memory_total_bytes${d} 63012864`),
				...family('ubnt_memory_free_bytes', 'gauge', 'Free memory of the radio, in bytes.', `ubnt_memory_free_bytes${d} 14909440`),
				...family('ubnt_temperature_celsius', 'gauge', 'Temperature of the radio, in Celsius.', `ubnt_temperature_celsius${d} 0`),
				...family('ubnt_cpu_load_ratio', 'gauge', 'CPU load of the radio, from 0 to 1.', `ubnt_cpu_load_ratio${d} 0.07920792`),
				...family('ubnt_time_seconds', 'gauge', 'Unix time on the radio.', `ubnt_time_seconds${d} 1790856000`),
				...family('ubnt_band', 'gauge', 'The wireless band.', `ubnt_band${d} 2`),
				...family('ubnt_frequency_hertz', 'gauge', 'The wireless frequency, in hertz.', `ubnt_frequency_hertz${d} 5540000000`),
				...family('ubnt_center1_frequency_hertz', 'gauge', 'Center frequency of the channel, in hertz.', `ubnt_center1_frequency_hertz${d} 5550000000`),
				...family('ubnt_dfs', 'gauge', 'Whether the channel needs DFS.', `ubnt_dfs${d} 1`),
				...family('ubnt_distance_meters', 'gauge', 'Link distance, in meters.', `ubnt_distance_meters${d} 1350`),
				...family('ubnt_noise_floor_dbm', 'gauge', 'Noise floor, in dBm.', `ubnt_noise_floor_dbm${d} -94`),
				...family('ubnt_transmit_power_dbm', 'gauge', 'Transmit power, in dBm.', `ubnt_transmit_power_dbm${d} 16`),
				...family('ubnt_ap_repeater', 'gauge', 'Whether the radio is an AP repeater.', `ubnt_ap_repeater${d} 0`),
				...family('ubnt_radio_status', 'gauge', 'Radio status.', `ubnt_radio_status${d} 5`),
				...family('ubnt_channel_width_hertz', 'gauge', 'Channel width, in hertz.', `ubnt_channel_width_hertz${d} 40000000`),
				...family('ubnt_rx_chainmask', 'gauge', 'Receive chain mask.', `ubnt_rx_chainmask${d} 3`),
				...family('ubnt_tx_chainmask', 'gauge', 'Transmit chain mask.', `ubnt_tx_chainmask${d} 3`),
				...family('ubnt_cac_state', 'gauge', 'DFS channel availability check state.', `ubnt_cac_state${d} 0`),
				...family('ubnt_cac_timeout', 'gauge', 'DFS channel availability check timeout.', `ubnt_cac_timeout${d} 0`),
				...family('ubnt_rx_idx', 'gauge', 'Receive modulation index.', `ubnt_rx_idx${d} 8`),
				...family('ubnt_rx_nss', 'gauge', 'Receive spatial streams.', `ubnt_rx_nss${d} 2`),
				...family('ubnt_tx_idx', 'gauge', 'Transmit modulation index.', `ubnt_tx_idx${d} 9`),
				...family('ubnt_tx_nss', 'gauge', 'Transmit spatial streams.', `ubnt_tx_nss${d} 2`),
				...family('ubnt_stations', 'gauge', 'Stations associated.', `ubnt_stations${d} 1`),
				...family('ubnt_transmit_throughput_bits_per_second', 'gauge', 'Transmit throughput, in bits per second.', `ubnt_transmit_throughput_bits_per_second${d} 1843000`),
				...family('ubnt_receive_throughput_bits_per_second', 'gauge', 'Receive throughput, in bits per second.', `ubnt_receive_throughput_bits_per_second${d} 20512000`),
				...family('ubnt_airmax_combined_capacity_bits_per_second', 'gauge', 'airMAX combined capacity, in bits per second.', `ubnt_airmax_combined_capacity_bits_per_second${d} 331140000`),
				...family('ubnt_airmax_downlink_capacity_bits_per_second', 'gauge', 'airMAX download capacity, in bits per second.', `ubnt_airmax_downlink_capacity_bits_per_second${d} 297720000`),
				...family('ubnt_airmax_uplink_capacity_bits_per_second', 'gauge', 'airMAX upload capacity, in bits per second.', `ubnt_airmax_uplink_capacity_bits_per_second${d} 253920000`),
				...family('ubnt_airtime_use', 'gauge', 'Airtime use, as airOS reports it.', `ubnt_airtime_use${d} 17`),
				...family('ubnt_transmit_airtime_use', 'gauge', 'Transmit airtime use, as airOS reports it.', `ubnt_transmit_airtime_use${d} 8`),
				...family('ubnt_receive_airtime_use', 'gauge', 'Receive airtime use, as airOS reports it.', `ubnt_receive_airtime_use${d} 9`),
				...family('ubnt_atpc_status', 'gauge', 'Automatic transmit power control status.', `ubnt_atpc_status${d} 2`),
			], r.lines);
		});
	});

	it('exports an airOS 6 radio, its frequency read from "5745 MHz" and its memory from kB', () => {
		run({ [LIST]: { out: 'nsloco\n' }, [status('nsloco')]: { out: AIROS6 } }, (r) => {
			let d = '{device="nsloco"}';

			assert.match(true, r.result.ok);
			assert.match([
				...family('ubnt_info', 'gauge', 'The radio, by its names and firmware.',
					'ubnt_info{device="nsloco",hostname="link-south",devmodel="NanoStation loco M5",fwversion="XW.v6.3.6",essid="backhaul"} 1'),
				...family('ubnt_uptime_seconds', 'gauge', 'Seconds since the radio booted.', `ubnt_uptime_seconds${d} 532104`),
				...family('ubnt_memory_total_bytes', 'gauge', 'Total memory of the radio, in bytes.', `ubnt_memory_total_bytes${d} 62586880`),
				...family('ubnt_memory_free_bytes', 'gauge', 'Free memory of the radio, in bytes.', `ubnt_memory_free_bytes${d} 20623360`),
				...family('ubnt_cpu_load_ratio', 'gauge', 'CPU load of the radio, from 0 to 1.', `ubnt_cpu_load_ratio${d} 0.14`),
				...family('ubnt_cpu_busy', 'gauge', 'Busy CPU time of the radio, as airOS counts it.', `ubnt_cpu_busy${d} 3521`),
				...family('ubnt_cpu_all', 'gauge', 'All CPU time of the radio, as airOS counts it.', `ubnt_cpu_all${d} 25150`),
				...family('ubnt_channel', 'gauge', 'The wireless channel.', `ubnt_channel${d} 149`),
				...family('ubnt_frequency_hertz', 'gauge', 'The wireless frequency, in hertz.', `ubnt_frequency_hertz${d} 5745000000`),
				...family('ubnt_dfs', 'gauge', 'Whether the channel needs DFS.', `ubnt_dfs${d} 0`),
				...family('ubnt_signal_dbm', 'gauge', 'Signal strength, in dBm.', `ubnt_signal_dbm${d} -62`),
				...family('ubnt_rssi', 'gauge', 'Received signal strength indicator.', `ubnt_rssi${d} 34`),
				...family('ubnt_noise_floor_dbm', 'gauge', 'Noise floor, in dBm.', `ubnt_noise_floor_dbm${d} -96`),
				...family('ubnt_transmit_power_dbm', 'gauge', 'Transmit power, in dBm.', `ubnt_transmit_power_dbm${d} 20`),
				...family('ubnt_distance_meters', 'gauge', 'Link distance, in meters.', `ubnt_distance_meters${d} 1200`),
				...family('ubnt_transmit_rate_bits_per_second', 'gauge', 'Transmit rate, in bits per second.', `ubnt_transmit_rate_bits_per_second${d} 150000000`),
				...family('ubnt_receive_rate_bits_per_second', 'gauge', 'Receive rate, in bits per second.', `ubnt_receive_rate_bits_per_second${d} 135000000`),
				...family('ubnt_stations', 'gauge', 'Stations associated.', `ubnt_stations${d} 1`),
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
				'# TYPE ubnt_frequency_hertz gauge',
				'ubnt_frequency_hertz{device="litebeam"} 5540000000',
				'ubnt_frequency_hertz{device="nsloco"} 5745000000',
			]), r.lines);
		});
	});

	it('has nothing to observe when no radio is configured', () => {
		run({ [LIST]: { out: ' \n' } }, (r) => {
			assert.match({ ok: true, none: 'ubnt-manager lists no radios', error: null, lines: [], logs: [] }, outcome(r));
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

	// An unreachable radio: ssh waits on it until exec's watchdog kills it.
	it('keeps the other radios when one does not answer in time', () => {
		run({
			[LIST]: { out: 'gone nsloco\n' },
			[status('gone')]: { hangs: true },
			[status('nsloco')]: { out: AIROS6 },
		}, (r) => {
			assert.match({ ok: false, error: 'COMMAND_TIMEOUT', details: 'ubnt-manager: still running after 5 s, killed' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match(contains([ 'ubnt_channel{device="nsloco"} 149' ]), samples(r.lines));
		});
	});

	// The package does not depend on ubnt-manager: where it is not installed,
	// the shell cannot find it (127), and there is no radio to watch.
	it('has nothing to observe when ubnt-manager is not installed', () => {
		run({ [LIST]: { out: '', status: 127 } }, (r) => {
			assert.match({ ok: true, none: 'ubnt-manager is not installed' }, { ok: r.result.ok, none: r.result.none });
			assert.match([], r.lines);
		});
	});

	it('fails with COMMAND_FAILED when ubnt-manager cannot list the devices', () => {
		run({ [LIST]: { out: '', status: 1 } }, (r) => {
			assert.match({ ok: false, error: 'COMMAND_FAILED' }, { ok: r.result.ok, error: r.result.error });
			assert.match([], r.lines);
		});
	});

	it('reads the numbers status.cgi gives as numbers, strings and booleans', () => {
		assert.match([ 150, -62, 5745, 1, 0, null, null ],
			map([ 150, '-62', '5745 MHz', true, false, '--', null ], ubnt_manager.number));
	});

	prop('scales an airOS 8 radio\'s MHz to hertz, kbit/s to bits per second and percent to a ratio',
		gen.tuple(gen.int(2400, 6000), gen.int(0, 1000000), gen.int(0, 100)), (x) => {
			let doc = json(substr(AIROS8, 2));
			doc.wireless.frequency = x[0];
			doc.wireless.throughput.tx = x[1];
			doc.host.cpuload = x[2];

			run({ [LIST]: { out: 'litebeam\n' }, [status('litebeam')]: { out: sprintf('%J', doc) } }, (r) => {
				assert.match(contains([
					`ubnt_cpu_load_ratio{device="litebeam"} ${format_value(x[2] * 0.01)}`,
					`ubnt_frequency_hertz{device="litebeam"} ${x[0] * 1000000}`,
					`ubnt_transmit_throughput_bits_per_second{device="litebeam"} ${x[1] * 1000}`,
				]), r.lines);
			});
		});
});

describe('ubnt-manager in the jail', () => {
	it('gets the shell, the script and what the script sources and runs', () => {
		assert.match(sort([ '/bin/sh', '/usr/bin/ubnt-manager', ...ubnt_manager.SCRIPT_NEEDS ]),
			jail_of(ubnt_manager, { files: [ '/usr/bin/ubnt-manager' ] }).mounts);
	});
});
