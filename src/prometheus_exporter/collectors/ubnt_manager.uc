'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/ubnt-manager.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors } from 'prometheus_exporter.api';

// ubnt-manager is a shell script: in the jail it needs what it sources and
// runs, besides the shell. It reads its devices with config_load (functions.sh,
// uci.sh and the uci command, from its own config), sources jshn.sh, which
// runs jshn, and runs ssh (dropbear's) and sed. A busybox applet is its own
// path, as the jail has no other.
export const SCRIPT_NEEDS = [
	'/etc/config/ubnt-manager', '/lib/functions.sh', '/lib/config/uci.sh', '/sbin/uci',
	'/usr/share/libubox/jshn.sh', '/usr/bin/jshn', '/usr/bin/ssh', '/bin/sed',
];

export const meta = {
	name: 'ubnt-manager',
	title: 'Ubiquiti airOS radios',
	help: 'Ubiquiti airOS radios, from their status as ubnt-manager reads it over ssh.',
	needs: [ 'exec' ],
	commands: [ 'ubnt-manager' ],
	// ubnt-manager is what it watches, not what it needs: without it, nothing to observe.
	optional_commands: [ 'ubnt-manager' ],
	paths: SCRIPT_NEEDS,
};

// [ name, path in status.cgi's JSON, help, scale ]: every value is a gauge, a
// reading of now, in base units (status.cgi's MHz, Mbit/s, kbit/s and percent
// scaled to hertz, bits per second and ratios). The radio's names and firmware
// are node_ubnt_info's labels. airOS 6 gives memory in kB, airOS 8 in bytes;
// the airtime use is left as airOS gives it, its scale unknown.
const MHZ = 1000000, MBIT = 1000000, KBIT = 1000, KB = 1024, PERCENT = 0.01;

const AIROS6 = [
	[ 'ubnt_uptime_seconds', [ 'host', 'uptime' ], 'Seconds since the radio booted.' ],
	[ 'ubnt_memory_total_bytes', [ 'host', 'totalram' ], 'Total memory of the radio, in bytes.', KB ],
	[ 'ubnt_memory_free_bytes', [ 'host', 'freeram' ], 'Free memory of the radio, in bytes.', KB ],
	[ 'ubnt_cpu_load_ratio', [ 'host', 'cpuload' ], 'CPU load of the radio, from 0 to 1.', PERCENT ],
	[ 'ubnt_cpu_busy', [ 'host', 'cpubusy' ], 'Busy CPU time of the radio, as airOS counts it.' ],
	[ 'ubnt_cpu_all', [ 'host', 'cputotal' ], 'All CPU time of the radio, as airOS counts it.' ],
	[ 'ubnt_channel', [ 'wireless', 'channel' ], 'The wireless channel.' ],
	[ 'ubnt_frequency_hertz', [ 'wireless', 'frequency' ], 'The wireless frequency, in hertz.', MHZ ],
	[ 'ubnt_dfs', [ 'wireless', 'dfs' ], 'Whether the channel needs DFS.' ],
	[ 'ubnt_signal_dbm', [ 'wireless', 'signal' ], 'Signal strength, in dBm.' ],
	[ 'ubnt_rssi', [ 'wireless', 'rssi' ], 'Received signal strength indicator.' ],
	[ 'ubnt_noise_floor_dbm', [ 'wireless', 'noisef' ], 'Noise floor, in dBm.' ],
	[ 'ubnt_transmit_power_dbm', [ 'wireless', 'txpower' ], 'Transmit power, in dBm.' ],
	[ 'ubnt_distance_meters', [ 'wireless', 'distance' ], 'Link distance, in meters.' ],
	[ 'ubnt_transmit_rate_bits_per_second', [ 'wireless', 'txrate' ], 'Transmit rate, in bits per second.', MBIT ],
	[ 'ubnt_receive_rate_bits_per_second', [ 'wireless', 'rxrate' ], 'Receive rate, in bits per second.', MBIT ],
	[ 'ubnt_stations', [ 'wireless', 'count' ], 'Stations associated.' ],
];

const AIROS8 = [
	[ 'ubnt_uptime_seconds', [ 'host', 'uptime' ], 'Seconds since the radio booted.' ],
	[ 'ubnt_loadavg', [ 'host', 'loadavg' ], 'Load average of the radio.' ],
	[ 'ubnt_memory_total_bytes', [ 'host', 'totalram' ], 'Total memory of the radio, in bytes.' ],
	[ 'ubnt_memory_free_bytes', [ 'host', 'freeram' ], 'Free memory of the radio, in bytes.' ],
	[ 'ubnt_temperature_celsius', [ 'host', 'temperature' ], 'Temperature of the radio, in Celsius.' ],
	[ 'ubnt_cpu_load_ratio', [ 'host', 'cpuload' ], 'CPU load of the radio, from 0 to 1.', PERCENT ],
	[ 'ubnt_time_seconds', [ 'host', 'timestamp' ], 'Unix time on the radio.' ],
	[ 'ubnt_band', [ 'wireless', 'band' ], 'The wireless band.' ],
	[ 'ubnt_frequency_hertz', [ 'wireless', 'frequency' ], 'The wireless frequency, in hertz.', MHZ ],
	[ 'ubnt_center1_frequency_hertz', [ 'wireless', 'center1_freq' ], 'Center frequency of the channel, in hertz.', MHZ ],
	[ 'ubnt_dfs', [ 'wireless', 'dfs' ], 'Whether the channel needs DFS.' ],
	[ 'ubnt_distance_meters', [ 'wireless', 'distance' ], 'Link distance, in meters.' ],
	[ 'ubnt_noise_floor_dbm', [ 'wireless', 'noisef' ], 'Noise floor, in dBm.' ],
	[ 'ubnt_transmit_power_dbm', [ 'wireless', 'txpower' ], 'Transmit power, in dBm.' ],
	[ 'ubnt_ap_repeater', [ 'wireless', 'aprepeater' ], 'Whether the radio is an AP repeater.' ],
	[ 'ubnt_radio_status', [ 'wireless', 'rstatus' ], 'Radio status.' ],
	[ 'ubnt_channel_width_hertz', [ 'wireless', 'chanbw' ], 'Channel width, in hertz.', MHZ ],
	[ 'ubnt_rx_chainmask', [ 'wireless', 'rx_chainmask' ], 'Receive chain mask.' ],
	[ 'ubnt_tx_chainmask', [ 'wireless', 'tx_chainmask' ], 'Transmit chain mask.' ],
	[ 'ubnt_cac_state', [ 'wireless', 'cac_state' ], 'DFS channel availability check state.' ],
	[ 'ubnt_cac_timeout', [ 'wireless', 'cac_timeout' ], 'DFS channel availability check timeout.' ],
	[ 'ubnt_rx_idx', [ 'wireless', 'rx_idx' ], 'Receive modulation index.' ],
	[ 'ubnt_rx_nss', [ 'wireless', 'rx_nss' ], 'Receive spatial streams.' ],
	[ 'ubnt_tx_idx', [ 'wireless', 'tx_idx' ], 'Transmit modulation index.' ],
	[ 'ubnt_tx_nss', [ 'wireless', 'tx_nss' ], 'Transmit spatial streams.' ],
	[ 'ubnt_stations', [ 'wireless', 'count' ], 'Stations associated.' ],
	[ 'ubnt_transmit_throughput_bits_per_second', [ 'wireless', 'throughput', 'tx' ], 'Transmit throughput, in bits per second.', KBIT ],
	[ 'ubnt_receive_throughput_bits_per_second', [ 'wireless', 'throughput', 'rx' ], 'Receive throughput, in bits per second.', KBIT ],
	[ 'ubnt_airmax_combined_capacity_bits_per_second', [ 'wireless', 'polling', 'cb_capacity' ], 'airMAX combined capacity, in bits per second.', KBIT ],
	[ 'ubnt_airmax_downlink_capacity_bits_per_second', [ 'wireless', 'polling', 'dl_capacity' ], 'airMAX download capacity, in bits per second.', KBIT ],
	[ 'ubnt_airmax_uplink_capacity_bits_per_second', [ 'wireless', 'polling', 'ul_capacity' ], 'airMAX upload capacity, in bits per second.', KBIT ],
	[ 'ubnt_airtime_use', [ 'wireless', 'polling', 'use' ], 'Airtime use, as airOS reports it.' ],
	[ 'ubnt_transmit_airtime_use', [ 'wireless', 'polling', 'tx_use' ], 'Transmit airtime use, as airOS reports it.' ],
	[ 'ubnt_receive_airtime_use', [ 'wireless', 'polling', 'rx_use' ], 'Receive airtime use, as airOS reports it.' ],
	[ 'ubnt_atpc_status', [ 'wireless', 'polling', 'atpc_status' ], 'Automatic transmit power control status.' ],
];

function dig(data, path) {
	for (let key in path)
		data = type(data) == 'object' ? data[key] : null;

	return data;
}

// A number status.cgi gives, as a number or a string ("150"; airOS 6's
// frequency is "5745 MHz"), or null.
export function number(v) {
	if (type(v) in [ 'int', 'double' ])
		return v;
	if (type(v) == 'bool')
		return v ? 1 : 0;

	let m = (type(v) == 'string') ? match(trim(v), /^(-?[0-9]+(\.[0-9]+)?)([[:space:]]+[A-Za-z]+)?$/) : null;
	return m ? +m[1] : null;
};

function device_metrics(out, specs, data, device) {
	for (let spec in specs) {
		let v = number(dig(data, spec[1]));

		out.gauge(spec[0], spec[2])({ device }, (v != null && spec[3]) ? v * spec[3] : v);
	}
}

// The status of one device, or an error Result.
function status(exec, device) {
	let res = exec.run([ 'ubnt-manager', '-j', '-t', device ]);

	if (!res.ok)
		return res;

	try {
		return Result.ok(json(res.data));
	} catch (e) {
		return Result.err(errors.SOURCE_INVALID, `ubnt-manager -j -t ${device}: ${e.message}`);
	}
}

// The shell's status for a program it cannot find.
const NOT_FOUND = 127;

// ubnt-manager not installed, or without a radio in its config, has nothing to
// observe.
export function collect(deps, out) {
	let res = deps.exec.run([ 'ubnt-manager', '-l' ]);
	if (!res.ok)
		return (res.data?.status == NOT_FOUND) ? Result.none('ubnt-manager is not installed') : res;

	let devices = filter(split(trim(res.data ?? ''), /\s+/), (d) => d != '');
	if (!length(devices))
		return Result.none('ubnt-manager lists no radios');

	let failed = null;

	// A device that fails is the collector's error once the others are in.
	for (let device in devices) {
		let st = status(deps.exec, device);
		if (!st.ok) {
			failed ??= st;
			continue;
		}

		let host = st.data?.host, wireless = st.data?.wireless;
		if (type(host) != 'object' || type(wireless) != 'object')
			continue;

		let fw = '' + (host.fwversion ?? '');
		let specs = (index(fw, 'v8.') >= 0) ? AIROS8 : (index(fw, 'v6.') >= 0) ? AIROS6 : null;

		if (!specs)
			continue;

		out.gauge('ubnt_info', 'The radio, by its names and firmware.')({
			device,
			hostname: host.hostname,
			devmodel: host.devmodel,
			fwversion: host.fwversion,
			essid: wireless.essid,
		}, 1);
		device_metrics(out, specs, st.data, device);
	}

	return failed ?? Result.ok();
};
