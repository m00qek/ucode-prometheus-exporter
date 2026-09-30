'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/ubnt-manager.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'ubnt-manager',
	help: 'Ubiquiti airOS radios, from their status as ubnt-manager reads it over ssh.',
	needs: [ 'exec' ],
	commands: [ 'ubnt-manager' ],
};

// [ name, type, path in status.cgi's JSON, help ]. ubnt_uptime carries the full
// labels (device, hostname, devmodel, fwversion, essid), the others only device.
const AIROS6 = [
	[ 'ubnt_uptime', 'counter', [ 'host', 'uptime' ], 'Seconds since the radio booted.' ],
	[ 'ubnt_totalram', 'gauge', [ 'host', 'totalram' ], 'Total memory of the radio.' ],
	[ 'ubnt_freeram', 'gauge', [ 'host', 'freeram' ], 'Free memory of the radio.' ],
	[ 'ubnt_cpuload', 'gauge', [ 'host', 'cpuload' ], 'CPU load of the radio, in percent.' ],
	[ 'ubnt_cpubusy', 'gauge', [ 'host', 'cpubusy' ], 'Busy CPU time of the radio.' ],
	[ 'ubnt_cputotal', 'gauge', [ 'host', 'cputotal' ], 'Total CPU time of the radio.' ],
	[ 'ubnt_channel', 'gauge', [ 'wireless', 'channel' ], 'The wireless channel.' ],
	[ 'ubnt_frequency', 'gauge', [ 'wireless', 'frequency' ], 'The wireless frequency, in MHz.' ],
	[ 'ubnt_dfs', 'gauge', [ 'wireless', 'dfs' ], 'Whether the channel needs DFS.' ],
	[ 'ubnt_signal', 'gauge', [ 'wireless', 'signal' ], 'Signal strength, in dBm.' ],
	[ 'ubnt_rssi', 'gauge', [ 'wireless', 'rssi' ], 'Received signal strength indicator.' ],
	[ 'ubnt_noisef', 'gauge', [ 'wireless', 'noisef' ], 'Noise floor, in dBm.' ],
	[ 'ubnt_txpower', 'gauge', [ 'wireless', 'txpower' ], 'Transmit power, in dBm.' ],
	[ 'ubnt_distance', 'gauge', [ 'wireless', 'distance' ], 'Link distance, in meters.' ],
	[ 'ubnt_txrate', 'gauge', [ 'wireless', 'txrate' ], 'Transmit rate, in Mbit/s.' ],
	[ 'ubnt_rxrate', 'gauge', [ 'wireless', 'rxrate' ], 'Receive rate, in Mbit/s.' ],
	[ 'ubnt_count', 'gauge', [ 'wireless', 'count' ], 'Stations associated.' ],
];

const AIROS8 = [
	[ 'ubnt_uptime', 'counter', [ 'host', 'uptime' ], 'Seconds since the radio booted.' ],
	[ 'ubnt_loadavg', 'gauge', [ 'host', 'loadavg' ], 'Load average of the radio.' ],
	[ 'ubnt_totalram', 'gauge', [ 'host', 'totalram' ], 'Total memory of the radio.' ],
	[ 'ubnt_freeram', 'gauge', [ 'host', 'freeram' ], 'Free memory of the radio.' ],
	[ 'ubnt_temperature', 'gauge', [ 'host', 'temperature' ], 'Temperature of the radio.' ],
	[ 'ubnt_cpuload', 'gauge', [ 'host', 'cpuload' ], 'CPU load of the radio, in percent.' ],
	[ 'ubnt_timestamp', 'counter', [ 'host', 'timestamp' ], 'Unix time on the radio.' ],
	[ 'ubnt_band', 'gauge', [ 'wireless', 'band' ], 'The wireless band.' ],
	[ 'ubnt_frequency', 'gauge', [ 'wireless', 'frequency' ], 'The wireless frequency, in MHz.' ],
	[ 'ubnt_center1_freq', 'gauge', [ 'wireless', 'center1_freq' ], 'Center frequency of the channel, in MHz.' ],
	[ 'ubnt_dfs', 'gauge', [ 'wireless', 'dfs' ], 'Whether the channel needs DFS.' ],
	[ 'ubnt_distance', 'gauge', [ 'wireless', 'distance' ], 'Link distance, in meters.' ],
	[ 'ubnt_noisef', 'gauge', [ 'wireless', 'noisef' ], 'Noise floor, in dBm.' ],
	[ 'ubnt_txpower', 'gauge', [ 'wireless', 'txpower' ], 'Transmit power, in dBm.' ],
	[ 'ubnt_aprepeater', 'gauge', [ 'wireless', 'aprepeater' ], 'Whether the radio is an AP repeater.' ],
	[ 'ubnt_rstatus', 'gauge', [ 'wireless', 'rstatus' ], 'Radio status.' ],
	[ 'ubnt_chanbw', 'gauge', [ 'wireless', 'chanbw' ], 'Channel width, in MHz.' ],
	[ 'ubnt_rx_chainmask', 'gauge', [ 'wireless', 'rx_chainmask' ], 'Receive chain mask.' ],
	[ 'ubnt_tx_chainmask', 'gauge', [ 'wireless', 'tx_chainmask' ], 'Transmit chain mask.' ],
	[ 'ubnt_cac_state', 'gauge', [ 'wireless', 'cac_state' ], 'DFS channel availability check state.' ],
	[ 'ubnt_cac_timeout', 'gauge', [ 'wireless', 'cac_timeout' ], 'DFS channel availability check timeout.' ],
	[ 'ubnt_rx_idx', 'gauge', [ 'wireless', 'rx_idx' ], 'Receive modulation index.' ],
	[ 'ubnt_rx_nss', 'gauge', [ 'wireless', 'rx_nss' ], 'Receive spatial streams.' ],
	[ 'ubnt_tx_idx', 'gauge', [ 'wireless', 'tx_idx' ], 'Transmit modulation index.' ],
	[ 'ubnt_tx_nss', 'gauge', [ 'wireless', 'tx_nss' ], 'Transmit spatial streams.' ],
	[ 'ubnt_count', 'gauge', [ 'wireless', 'count' ], 'Stations associated.' ],
	[ 'ubnt_throughput_tx', 'gauge', [ 'wireless', 'throughput', 'tx' ], 'Transmit throughput, in kbit/s.' ],
	[ 'ubnt_throughput_rx', 'gauge', [ 'wireless', 'throughput', 'rx' ], 'Receive throughput, in kbit/s.' ],
	[ 'ubnt_polling_cb_capacity', 'gauge', [ 'wireless', 'polling', 'cb_capacity' ], 'airMAX combined capacity, in kbit/s.' ],
	[ 'ubnt_polling_dl_capacity', 'gauge', [ 'wireless', 'polling', 'dl_capacity' ], 'airMAX download capacity, in kbit/s.' ],
	[ 'ubnt_polling_ul_capacity', 'gauge', [ 'wireless', 'polling', 'ul_capacity' ], 'airMAX upload capacity, in kbit/s.' ],
	[ 'ubnt_use', 'gauge', [ 'wireless', 'polling', 'use' ], 'airtime use, in percent.' ],
	[ 'ubnt_tx_use', 'gauge', [ 'wireless', 'polling', 'tx_use' ], 'Transmit airtime use, in percent.' ],
	[ 'ubnt_rx_use', 'gauge', [ 'wireless', 'polling', 'rx_use' ], 'Receive airtime use, in percent.' ],
	[ 'ubnt_atpc_status', 'gauge', [ 'wireless', 'polling', 'atpc_status' ], 'Automatic transmit power control status.' ],
];

function dig(data, path) {
	for (let key in path)
		data = type(data) == 'object' ? data[key] : null;

	return data;
}

// airOS 6 reports the frequency as "5745 MHz".
function frequency6(v) {
	return type(v) == 'string' ? split(trim(v), /\s+/)[0] : v;
}

function device_metrics(out, specs, data, device, full, v6) {
	for (let spec in specs) {
		let name = spec[0];
		let value = dig(data, spec[2]);

		if (v6 && name == 'ubnt_frequency')
			value = frequency6(value);

		let sample = spec[1] == 'counter' ? out.counter(name, spec[3]) : out.gauge(name, spec[3]);
		sample(name == 'ubnt_uptime' ? full : { device }, value);
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

export function collect(deps, out) {
	let res = deps.exec.run([ 'ubnt-manager', '-l' ]);
	if (!res.ok)
		return res;

	let failed = null;

	// A device that fails is the collector's error once the others are in.
	for (let device in split(trim(res.data ?? ''), /\s+/)) {
		if (device == '')
			continue;

		let st = status(deps.exec, device);
		if (!st.ok) {
			failed ??= st;
			continue;
		}

		let host = st.data?.host, wireless = st.data?.wireless;
		if (type(host) != 'object' || type(wireless) != 'object')
			continue;

		let full = {
			device,
			hostname: host.hostname,
			devmodel: host.devmodel,
			fwversion: host.fwversion,
			essid: wireless.essid,
		};

		let fw = '' + (host.fwversion ?? '');
		if (index(fw, 'v8.') >= 0)
			device_metrics(out, AIROS8, st.data, device, full, false);
		else if (index(fw, 'v6.') >= 0)
			device_metrics(out, AIROS6, st.data, device, full, true);
	}

	return failed ?? Result.ok();
};
