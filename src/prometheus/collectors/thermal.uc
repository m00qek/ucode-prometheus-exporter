'use strict';

import { Result, proc } from 'prometheus.exporter';

const ZONE = /^thermal_zone([0-9]+)$/;
const COOLING_DEVICE = /^cooling_device([0-9]+)$/;

export const meta = {
	name: 'thermal',
	title: 'Thermal zones and cooling devices',
	help: 'Thermal zone temperatures and cooling device states, from /sys/class/thermal.',
	needs: [ 'fs' ],
};

const ROOT = '/sys/class/thermal';
const INTEGER = /^-?[0-9]+$/;

function read_value(fs, path) {
	let line = proc.first_line(fs, path);

	return line == null ? null : trim(line);
}

const TRIPS_MAX = 32;

function critical(fs, dir) {
	let lowest = null;

	for (let k = 0; k < TRIPS_MAX; k++) {
		let kind = read_value(fs, `${dir}/trip_point_${k}_type`);

		if (kind == null)
			break;
		if (kind != 'critical')
			continue;

		let t = read_value(fs, `${dir}/trip_point_${k}_temp`);

		if (t != null && match(t, INTEGER) && int(t) > 0 && (lowest == null || int(t) < lowest))
			lowest = int(t);
	}

	return lowest;
}

export function collect(deps, out) {
	let fs = deps.fs;
	let temp = out.gauge('node_thermal_zone_temp', 'Zone temperature in Celsius');
	let info = out.gauge('node_thermal_zone_info', 'A thermal zone, by its policy and mode.');
	let passive_celsius = out.gauge('node_thermal_zone_passive_celsius', 'Passive trip point of the zone, in Celsius.');
	let critical_celsius = out.gauge('node_thermal_zone_critical_celsius', 'Critical trip point of the zone, in Celsius: the kernel shuts the system down at it.');
	let cur_state = out.gauge('node_cooling_device_cur_state', 'Current throttle state of the cooling device');
	let max_state = out.gauge('node_cooling_device_max_state', 'Maximum throttle state of the cooling device');
	let zones = [], devices = [];

	for (let e in fs.lsdir(ROOT) ?? []) {
		let m = match(e, ZONE);
		if (m) {
			push(zones, int(m[1]));
			continue;
		}

		m = match(e, COOLING_DEVICE);
		if (m)
			push(devices, int(m[1]));
	}

	for (let zone in sort(zones, (a, b) => a - b)) {
		let dir = `${ROOT}/thermal_zone${zone}`;
		let kind = read_value(fs, `${dir}/type`);
		let policy = read_value(fs, `${dir}/policy`);
		let millideg = read_value(fs, `${dir}/temp`);

		if (kind == null || policy == null || millideg == null || !match(millideg, INTEGER))
			continue;

		let labels = { zone, type: kind };
		let mode = read_value(fs, `${dir}/mode`);
		let passive = read_value(fs, `${dir}/passive`);

		temp(labels, int(millideg) / 1000.0);
		info({ ...labels, policy, mode }, 1);
		if (passive != null && match(passive, INTEGER))
			passive_celsius(labels, int(passive) / 1000.0);

		let crit = critical(fs, dir);

		if (crit != null)
			critical_celsius(labels, crit / 1000.0);
	}

	for (let n in sort(devices, (a, b) => a - b)) {
		let dir = `${ROOT}/cooling_device${n}`;
		let kind = read_value(fs, `${dir}/type`);

		if (kind == null)
			continue;

		let labels = { name: `${n}`, type: kind };
		let cur = read_value(fs, `${dir}/cur_state`);
		let max = read_value(fs, `${dir}/max_state`);

		if (cur != null && match(cur, INTEGER))
			cur_state(labels, int(cur));
		if (max != null && match(max, INTEGER))
			max_state(labels, int(max));
	}

	return Result.ok();
};
