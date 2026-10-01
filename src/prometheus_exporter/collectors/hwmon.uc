'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/hwmon.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's hwmon collector: every chip under /sys/class/hwmon, its
// sensor labels, temperatures and PWM duty cycles, named and labeled as
// node_exporter's hwmon collector (collector/hwmon_linux.go) has them; and, as
// node_exporter has them too, its fans, voltages, currents and power (READINGS),
// in base units: the kernel's millivolts, milliamperes and microwatts
// (Documentation/hwmon/sysfs-interface.rst) as volts, amperes and watts.
//
// A chip is named as node_exporter names it: the type and name of the device
// its `device` link resolves to, `<type>_<name>` (as thermal_thermal_zone0 or
// ieee80211_phy0), or else its `name` file, or else the hwmonN directory, each
// part cleaned (lowercase, every character but a-z, 0-9, ':' and '_' an
// underscore, no underscore at either end); chips that would share a name get
// their cleaned `name` file appended, or their hwmonN where that is shared too.
// node_hwmon_chip_names is written for the chips with a `name` file. A sensor
// file that cannot be read is left out rather than failing the chip. Only the
// chip's own directory is read, not its device's, once: of what it lists,
// only the files of the sensors' labels, temperature inputs, PWM outputs and
// READINGS are read, each named by one match at most.

import * as Result from 'prometheus_exporter.result';
import { first_line } from 'prometheus_exporter.proc';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const NUMBER = /[0-9]+/;
const CHIP = /^hwmon[0-9]+$/;
const INTEGER = /^-?[0-9]+$/;
const PWM_FILE = /^pwm[0-9]+$/;
// <type><number>_<item>: temp1_input, fan2_min, in0_alarm.
const SENSOR_FILE = /^([a-z]+)([0-9]+)_([a-z]+)$/;

// The readings of a sensor file <type><number>_<item> beside the temperature
// input, by `<type>_<item>`, as node_exporter names them and helps them:
// [ name, help, what the kernel's unit is of the base unit ].
const READINGS = {
	fan_input: [ 'node_hwmon_fan_rpm', 'Hardware monitor for fan revolutions per minute (input)', 1 ],
	fan_min: [ 'node_hwmon_fan_min_rpm', 'Hardware monitor for fan revolutions per minute (min)', 1 ],
	fan_alarm: [ 'node_hwmon_fan_alarm', 'Hardware sensor alarm status (fan)', 1 ],
	in_input: [ 'node_hwmon_in_volts', 'Hardware monitor for voltage (input)', 1000 ],
	in_min: [ 'node_hwmon_in_min_volts', 'Hardware monitor for voltage (min)', 1000 ],
	in_max: [ 'node_hwmon_in_max_volts', 'Hardware monitor for voltage (max)', 1000 ],
	in_alarm: [ 'node_hwmon_in_alarm', 'Hardware sensor alarm status (in)', 1 ],
	curr_input: [ 'node_hwmon_curr_amps', 'Hardware monitor for current (input)', 1000 ],
	power_input: [ 'node_hwmon_power_watt', 'Hardware monitor for power usage in watts (input)', 1000000 ],
};

export const meta = {
	name: 'hwmon',
	title: 'Hardware sensors',
	help: 'Hardware monitor chips: sensor labels, temperatures, PWM, fans, voltages, currents and power, from /sys/class/hwmon.',
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
// Sorted by the number each names, temp10_input after temp2_input, and then
// by name: each name's number matched once, not at each comparison.
function by_number(names) {
	let keyed = map(names, (n) => [ +(match(n, NUMBER)?.[0] ?? 0), n ]);

	sort(keyed, (a, b) => a[0] != b[0] ? a[0] - b[0] : (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
	return map(keyed, (k) => k[1]);
}

// An integer reading in its base unit: `per` of the kernel's unit make one.
function in_base_unit(v, per) {
	return per == 1 ? int(v) : int(v) / (per * 1.0);
}

export function collect(deps, out) {
	let fs = deps.fs;
	// node_exporter's help texts; that of the PWM is its fallback's.
	let chip_names = out.gauge('node_hwmon_chip_names', 'Annotation metric for human-readable chip names');
	let sensor_label = out.gauge('node_hwmon_sensor_label', 'Label for given chip and sensor');
	let temp_celsius = out.gauge('node_hwmon_temp_celsius', 'Hardware monitor for temperature (input)');
	let pwm = out.gauge('node_hwmon_pwm', 'Hardware monitor pwm element ');
	let readings = {};

	for (let key, r in READINGS)
		readings[key] = out.gauge(r[0], r[1]);

	// No hwmon class at all is a kernel without hwmon drivers, not a failure.
	let dirs = filter(fs.lsdir(ROOT) ?? [], (e) => match(e, CHIP));

	for (let c in chips(fs, by_number(dirs))) {
		let dir = c.dir;
		let chip = c.chip;

		if (c.name_file != null && clean(c.name_file) != '')
			chip_names({ chip, chip_name: clean(c.name_file) }, 1);

		// One pass, in sensor order: each family's samples come in that order.
		for (let e in by_number(fs.lsdir(dir) ?? [])) {
			if (length(e) > 6 && substr(e, -6) == '_label') {
				let label = read_value(fs, `${dir}/${e}`);

				if (label != null)
					sensor_label({ chip, sensor: substr(e, 0, -6), label }, 1);
				continue;
			}

			if (substr(e, 0, 3) == 'pwm') {
				let v = match(e, PWM_FILE) ? read_value(fs, `${dir}/${e}`) : null;

				if (v != null)
					pwm({ chip, sensor: e }, v);
				continue;
			}

			let m = match(e, SENSOR_FILE);
			let key = m ? `${m[1]}_${m[3]}` : null;
			let record = (key == 'temp_input') ? temp_celsius : readings[key];

			if (!record)
				continue;

			let v = read_value(fs, `${dir}/${e}`);

			if (v != null && match(v, INTEGER))
				record({ chip, sensor: m[1] + m[2] }, key == 'temp_input' ? int(v) / 1000.0 : in_base_unit(v, READINGS[key][2]));
		}
	}

	return Result.ok();
};
