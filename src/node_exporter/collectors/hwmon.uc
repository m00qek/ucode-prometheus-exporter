'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hwmon.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hwmon collector: every chip under /sys/class/hwmon, its
// sensor labels, temperatures and PWM duty cycles.
//
// A chip is named as the Lua exporter names it (after node_exporter): the type
// and name of the device its `device` link resolves to, `<type>_<name>` (as
// thermal_thermal_zone0 or ieee80211_phy0), or else its `name` file, or else the
// hwmonN directory. Unlike node_exporter, names are not lowercased or cleaned.
// A sensor file that cannot be read is left out rather than failing the chip.

import * as Result from 'node_exporter.result';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'hwmon',
	help: 'Hardware monitor chips, sensor labels, temperatures and PWM from /sys/class/hwmon.',
	needs: [ 'fs' ],
};

const ROOT = '/sys/class/hwmon';

function basename(path) {
	return split(rtrim(path, '/'), '/')[-1];
}

function dirname(path) {
	let parts = split(rtrim(path, '/'), '/');

	pop(parts);
	return join('/', parts);
}

// The trimmed first line of a file, or null when it cannot be read.
function read_value(fs, path) {
	let line = first_line(fs, path);

	return line == null ? null : trim(line);
}

function chip_of(fs, dir, chip_name) {
	let dev = fs.realpath(`${dir}/device`);

	if (dev == null)
		return chip_name;

	let dev_name = basename(dev);
	let dev_type = basename(dirname(dev));

	return dev_type != '' ? `${dev_type}_${dev_name}` : dev_name;
}

// The number a sensor file names: temp10_input sorts after temp2_input.
function sensor_order(a, b) {
	let na = +(match(a, /[0-9]+/)?.[0] ?? 0), nb = +(match(b, /[0-9]+/)?.[0] ?? 0);

	return na != nb ? na - nb : (a < b ? -1 : a > b ? 1 : 0);
}

export function collect(deps, out) {
	let fs = deps.fs;
	let chip_names = out.gauge('node_hwmon_chip_names', 'Annotation metric for human-readable chip names.');
	let sensor_label = out.gauge('node_hwmon_sensor_label', 'Label for a chip sensor.');
	let temp_celsius = out.gauge('node_hwmon_temp_celsius', 'Hardware monitor temperature (input).');
	let pwm = out.gauge('node_hwmon_pwm', 'Hardware monitor PWM duty cycle (0-255).');

	// No hwmon class at all is a kernel without hwmon drivers, not a failure.
	let chips = filter(fs.lsdir(ROOT) ?? [], (e) => match(e, /^hwmon[0-9]+$/));

	for (let hw in sort(chips, sensor_order)) {
		let dir = `${ROOT}/${hw}`;
		let entries = sort(fs.lsdir(dir) ?? [], sensor_order);
		let chip_name = read_value(fs, `${dir}/name`) ?? '';

		if (chip_name == '')
			chip_name = hw;

		let chip = chip_of(fs, dir, chip_name);
		chip_names({ chip, chip_name }, 1);

		for (let e in entries) {
			let m = match(e, /^(.+)_label$/);
			let label = m ? read_value(fs, `${dir}/${e}`) : null;

			if (label != null)
				sensor_label({ chip, sensor: m[1], label }, 1);
		}

		for (let e in entries) {
			let m = match(e, /^(temp[0-9]+)_input$/);
			let v = m ? read_value(fs, `${dir}/${e}`) : null;

			if (v != null && match(v, /^-?[0-9]+$/))
				temp_celsius({ chip, sensor: m[1] }, int(v) / 1000.0);
		}

		for (let e in entries) {
			let v = match(e, /^pwm[0-9]+$/) ? read_value(fs, `${dir}/${e}`) : null;

			if (v != null)
				pwm({ chip, sensor: e }, v);
		}
	}

	return Result.ok();
};
