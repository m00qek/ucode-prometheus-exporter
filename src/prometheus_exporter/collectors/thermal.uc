'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/thermal.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The Lua exporter's thermal collector: the temperature of every thermal zone
// in /sys/class/thermal, as node_exporter's thermal_zone collector
// (collector/thermal_zone_linux.go) has it, labeled with the zone number and
// type only. What the Lua collector had as labels besides is apart, so that a
// series stays one series: the policy and mode (where the zone has one) as
// node_thermal_zone_info, and the passive trip point, where the zone has one,
// as node_thermal_zone_passive_celsius.
//
// Unlike the Lua collector, which stops at the first zone it cannot read, a zone
// without a readable type, policy or temperature (a sensor that is asleep
// answers EAGAIN or ENODATA) is skipped and the others are still reported, and a
// temperature below zero keeps its sign.
//
// The cooling devices of /sys/class/thermal too, as node_exporter's
// thermal_zone collector has them beside the zones:
// node_cooling_device_cur_state and node_cooling_device_max_state, labeled
// with the device's number (`name`, 0 for cooling_device0) and type, as a
// fan's speed step (pwm-fan), a CPU's frequency step (cpufreq-cpu0) or a
// radio's transmit duty cycle (mt76's phyN). They are what the
// zones' trip points drive, in the same directory: a router that throttles
// shows it here, before its temperature does. A device whose type cannot be
// read is left out; one state that cannot be read, that state alone.

import { Result, proc } from 'prometheus_exporter.api';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
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

export function collect(deps, out) {
	let fs = deps.fs;
	let temp = out.gauge('node_thermal_zone_temp', 'Zone temperature in Celsius');
	let info = out.gauge('node_thermal_zone_info', 'A thermal zone, by its policy and mode.');
	let passive_celsius = out.gauge('node_thermal_zone_passive_celsius', 'Passive trip point of the zone, in Celsius.');
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
