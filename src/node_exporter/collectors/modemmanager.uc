'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/modemmanager.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { sanitize } from 'node_exporter.exposition';

// mmcli asks ModemManager over D-Bus, on the system bus's socket in this
// directory (the dbus package's /var/run/dbus/system_bus_socket); the
// directory, as the socket is made anew each time dbus starts.
export const DBUS_DIR = '/var/run/dbus';

export const meta = {
	name: 'modemmanager',
	help: 'Signal quality and strength of cellular modems, from mmcli.',
	needs: [ 'exec' ],
	commands: [ 'mmcli' ],
	paths: [ DBUS_DIR ],
};

// The JSON mmcli prints for these arguments, or an error Result.
function mmcli(exec, args) {
	let argv = [ 'mmcli', ...args, '-J' ];
	let res = exec.run(argv);

	if (!res.ok)
		return res;

	try {
		return Result.ok(json(res.data));
	} catch (e) {
		return Result.err(errors.SOURCE_INVALID, `${join(' ', argv)}: ${e.message}`);
	}
}

// mmcli prints every value as a string, and '--' for one it does not have.
function number(v) {
	if (type(v) in [ 'int', 'double' ])
		return v;

	return type(v) == 'string' && match(trim(v), /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)$/) ? +v : null;
}

// The unit of each measure `mmcli --signal-get` reports (ModemManager's
// MMSignal): powers in dBm, ratios of powers in dB, the refresh rate in
// seconds. A measure not listed has no unit in its name.
export const UNITS = {
	rssi: '_dbm', rsrp: '_dbm', rscp: '_dbm', io: '_dbm',
	rsrq: '_db', snr: '_db', sinr: '_db', ecio: '_db',
	rate: '_seconds',
};

// The family of a measure: modemmanager_signal_<technology>_<measure><unit>,
// as a metric name.
export function family_of(tech, measure) {
	return sanitize(`modemmanager_signal_${tech}_${measure}${UNITS[measure] ?? ''}`);
};

// For each number `mmcli --signal-get` reports: lte rssi, rsrq, rsrp and snr,
// umts rscp and ecio, and so on.
function signals(out, modem, signal) {
	for (let tech, measures in signal) {
		if (type(measures) != 'object')
			continue;

		for (let name, value in measures) {
			let v = number(value);
			if (v != null)
				out.gauge(family_of(tech, name), `The ${tech} ${name} of the modem signal.`)({ modem }, v);
		}
	}
}

export function collect(deps, out) {
	let res = mmcli(deps.exec, [ '-L' ]);
	if (!res.ok)
		return res;

	let modems = res.data?.['modem-list'];
	if (type(modems) != 'array')
		return Result.err(errors.SOURCE_INVALID, 'mmcli -L: no modem-list');

	let failed = null;

	// A modem that fails is logged as the collector's error once the others are in.
	for (let modem in modems) {
		res = mmcli(deps.exec, [ '-m', modem ]);
		if (res.ok) {
			let quality = number(res.data?.modem?.generic?.['signal-quality']?.value);
			out.gauge('modemmanager_signal_quality_ratio', 'Signal quality of the modem, from 0 to 1.')(
				{ modem }, quality == null ? null : quality / 100.0);
		} else {
			failed ??= res;
		}

		res = mmcli(deps.exec, [ '-m', modem, '--signal-get' ]);
		if (res.ok)
			signals(out, modem, res.data?.modem?.signal);
		else
			failed ??= res;
	}

	return failed ?? Result.ok();
};
