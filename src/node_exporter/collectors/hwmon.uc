'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hwmon.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hwmon collector: every chip under /sys/class/hwmon, its
// sensor labels, temperatures and PWM duty cycles, named and labeled as
// node_exporter's hwmon collector (collector/hwmon_linux.go) has them.
//
// A chip is named as node_exporter names it: the type and name of the device
// its `device` link resolves to, `<type>_<name>` (as thermal_thermal_zone0 or
// ieee80211_phy0), or else its `name` file, or else the hwmonN directory, each
// part cleaned (lowercase, every character but a-z, 0-9, ':' and '_' an
// underscore, no underscore at either end); chips that would share a name get
// their cleaned `name` file appended, or their hwmonN where that is shared too.
// node_hwmon_chip_names is written for the chips with a `name` file. A sensor
// file that cannot be read is left out rather than failing the chip. Only the
// chip's own directory is read, not its device's, and of the sensors only the
// labels, the temperature inputs and the PWM outputs.

import * as Result from 'node_exporter.result';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'hwmon',
	title: 'Hardware sensors',
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

// node_exporter's cleanMetricName.
export function clean(name) {
	return trim(replace(lc(name), /[^a-z0-9:_]/g, '_'), '_');
};

// The chip's name before telling apart chips that share it.
function base_name(fs, dir, hw, name_file) {
	let dev = fs.realpath(`${dir}/device`);

	if (dev != null) {
		let dev_name = clean(basename(dev));
		let dev_type = clean(basename(dirname(dev)));

		if (dev_type != '' && dev_name != '')
			return `${dev_type}_${dev_name}`;
		if (dev_name != '')
			return dev_name;
	}

	if (name_file != null && clean(name_file) != '')
		return clean(name_file);

	return clean(hw);
}

// { hw, dir, name_file, chip } of every chip, as node_exporter names them.
export function chips(fs, dirs) {
	let all = map(dirs, (hw) => {
		let dir = `${ROOT}/${hw}`;
		let name_file = read_value(fs, `${dir}/name`);

		return { hw, dir, name_file, chip: base_name(fs, dir, hw, name_file) };
	});
	let chip_count = {}, name_count = {};

	for (let c in all) {
		chip_count[c.chip] = (chip_count[c.chip] ?? 0) + 1;
		name_count[c.chip + '\n' + c.name_file] = (name_count[c.chip + '\n' + c.name_file] ?? 0) + 1;
	}

	for (let c in all) {
		if (chip_count[c.chip] < 2)
			continue;

		let suffix = clean(c.name_file ?? '');
		if (suffix == '' || name_count[c.chip + '\n' + c.name_file] > 1)
			suffix = clean(c.hw);

		c.chip = `${c.chip}_${suffix}`;
	}

	return all;
};

// The number a sensor file names: temp10_input sorts after temp2_input.
function sensor_order(a, b) {
	let na = +(match(a, /[0-9]+/)?.[0] ?? 0), nb = +(match(b, /[0-9]+/)?.[0] ?? 0);

	return na != nb ? na - nb : (a < b ? -1 : a > b ? 1 : 0);
}

export function collect(deps, out) {
	let fs = deps.fs;
	// node_exporter's help texts; that of the PWM is its fallback's.
	let chip_names = out.gauge('node_hwmon_chip_names', 'Annotation metric for human-readable chip names');
	let sensor_label = out.gauge('node_hwmon_sensor_label', 'Label for given chip and sensor');
	let temp_celsius = out.gauge('node_hwmon_temp_celsius', 'Hardware monitor for temperature (input)');
	let pwm = out.gauge('node_hwmon_pwm', 'Hardware monitor pwm element ');

	// No hwmon class at all is a kernel without hwmon drivers, not a failure.
	let dirs = filter(fs.lsdir(ROOT) ?? [], (e) => match(e, /^hwmon[0-9]+$/));

	for (let c in chips(fs, sort(dirs, sensor_order))) {
		let dir = c.dir;
		let chip = c.chip;
		let entries = sort(fs.lsdir(dir) ?? [], sensor_order);

		if (c.name_file != null && clean(c.name_file) != '')
			chip_names({ chip, chip_name: clean(c.name_file) }, 1);

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
