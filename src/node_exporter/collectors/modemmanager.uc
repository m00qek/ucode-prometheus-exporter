'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/modemmanager.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'modemmanager',
	help: 'Signal quality and strength of cellular modems, from mmcli.',
	needs: [ 'exec' ],
	commands: [ 'mmcli' ],
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

// modemmanager_signal_<technology>_<measure> for each number `mmcli --signal-get`
// reports: lte rssi, rsrq, rsrp and snr, umts rscp and ecio, and so on.
function signals(out, modem, signal) {
	for (let tech, measures in signal) {
		if (type(measures) != 'object')
			continue;

		for (let name, value in measures) {
			let v = number(value);
			if (v != null)
				out.gauge(`modemmanager_signal_${tech}_${name}`, `The ${tech} ${name} of the modem signal.`)({ modem }, v);
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
			out.gauge('modemmanager_signal_quality', 'Signal quality of the modem, in percent.')({ modem }, quality);
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
