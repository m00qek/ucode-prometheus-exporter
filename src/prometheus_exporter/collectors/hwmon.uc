'use strict';

import { Result, proc } from 'prometheus_exporter.api';

const NUMBER = /[0-9]+/;
const CHIP = /^hwmon[0-9]+$/;
const INTEGER = /^-?[0-9]+$/;
const PWM_FILE = /^pwm[0-9]+$/;
const SENSOR_FILE = /^([a-z]+)([0-9]+)_([a-z]+)$/;

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
	power_average: [ 'node_hwmon_power_average_watt', 'Hardware monitor for power usage in watts (average)', 1000000 ],
	temp_max: [ 'node_hwmon_temp_max_celsius', 'Hardware monitor for temperature (max)', 1000 ],
	temp_crit: [ 'node_hwmon_temp_crit_celsius', 'Hardware monitor for temperature (crit)', 1000 ],
	temp_alarm: [ 'node_hwmon_temp_alarm', 'Hardware sensor alarm status (temp)', 1 ],
};

export const meta = {
	name: 'hwmon',
	title: 'Hardware sensors',
	help: 'Hardware monitor chips: sensor labels, temperatures and their limits, PWM, fans, voltages, currents and power, from /sys/class/hwmon.',
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

function read_value(fs, path) {
	let line = proc.first_line(fs, path);

	return line == null ? null : trim(line);
}

export function clean(name) {
	return trim(replace(lc(name), /[^a-z0-9:_]/g, '_'), '_');
};

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
function by_number(names) {
	let keyed = map(names, (n) => [ +(match(n, NUMBER)?.[0] ?? 0), n ]);

	sort(keyed, (a, b) => a[0] != b[0] ? a[0] - b[0] : (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0));
	return map(keyed, (k) => k[1]);
}

function in_base_unit(v, per) {
	return per == 1 ? int(v) : int(v) / (per * 1.0);
}

export function collect(deps, out) {
	let fs = deps.fs;
	let chip_names = out.gauge('node_hwmon_chip_names', 'Annotation metric for human-readable chip names');
	let sensor_label = out.gauge('node_hwmon_sensor_label', 'Label for given chip and sensor');
	let temp_celsius = out.gauge('node_hwmon_temp_celsius', 'Hardware monitor for temperature (input)');
	let pwm = out.gauge('node_hwmon_pwm', 'Hardware monitor pwm element ');
	let readings = {};

	for (let key, r in READINGS)
		readings[key] = out.gauge(r[0], r[1]);

	let dirs = filter(fs.lsdir(ROOT) ?? [], (e) => match(e, CHIP));

	for (let c in chips(fs, by_number(dirs))) {
		let dir = c.dir;
		let chip = c.chip;

		if (c.name_file != null && clean(c.name_file) != '')
			chip_names({ chip, chip_name: clean(c.name_file) }, 1);

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
