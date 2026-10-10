'use strict';

import { Result, errors, services, exposition } from 'prometheus_exporter.api';

export const DBUS_DIR = '/var/run/dbus';

export const meta = {
	name: 'modemmanager',
	title: 'Cellular modems',
	help: 'Signal quality and strength of cellular modems, from mmcli.',
	needs: [ 'exec', 'ubus' ],
	ubus: { rc: [ 'list' ] },
	commands: [ 'mmcli' ],
	optional_commands: [ 'mmcli' ],
	paths: [ DBUS_DIR ],
};

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

function number(v) {
	if (type(v) in [ 'int', 'double' ])
		return v;

	return type(v) == 'string' && match(trim(v), /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)$/) ? +v : null;
}

export const UNITS = {
	rssi: '_dbm', rsrp: '_dbm', rscp: '_dbm', io: '_dbm',
	rsrq: '_db', snr: '_db', sinr: '_db', ecio: '_db',
	rate: '_seconds',
};

export function family_of(tech, measure) {
	return exposition.sanitize(`modemmanager_signal_${tech}_${measure}${UNITS[measure] ?? ''}`);
};

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
		return services.unless_disabled(deps.ubus, 'modemmanager', res);

	let modems = res.data?.['modem-list'];
	if (type(modems) != 'array')
		return Result.err(errors.SOURCE_INVALID, 'mmcli -L: no modem-list');
	if (!length(modems))
		return Result.none('ModemManager lists no modems');

	let failed = null;

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
