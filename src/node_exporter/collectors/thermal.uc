'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/thermal.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten in ucode; see NOTICE.

// The Lua exporter's thermal collector: the temperature of every thermal zone
// in /sys/class/thermal, labeled with its zone number, type and policy, and its
// mode and passive trip point where the zone has them.
//
// Unlike the Lua collector, which stops at the first zone it cannot read, a zone
// without a readable type, policy or temperature (a sensor that is asleep
// answers EAGAIN or ENODATA) is skipped and the others are still reported, and a
// temperature below zero keeps its sign.

import * as Result from 'node_exporter.result';
import { first_line } from 'node_exporter.proc';

export const meta = {
	name: 'thermal',
	help: 'Thermal zone temperatures from /sys/class/thermal.',
	needs: [ 'fs' ],
};

const ROOT = '/sys/class/thermal';
const INTEGER = /^-?[0-9]+$/;

function read_value(fs, path) {
	let line = first_line(fs, path);

	return line == null ? null : trim(line);
}

export function collect(deps, out) {
	let fs = deps.fs;
	let temp = out.gauge('node_thermal_zone_temp', 'Zone temperature in Celsius.');
	let zones = [];

	for (let e in fs.lsdir(ROOT) ?? []) {
		let m = match(e, /^thermal_zone([0-9]+)$/);
		if (m)
			push(zones, int(m[1]));
	}

	for (let zone in sort(zones, (a, b) => a - b)) {
		let dir = `${ROOT}/thermal_zone${zone}`;
		let kind = read_value(fs, `${dir}/type`);
		let policy = read_value(fs, `${dir}/policy`);
		let millideg = read_value(fs, `${dir}/temp`);

		if (kind == null || policy == null || millideg == null || !match(millideg, INTEGER))
			continue;

		let labels = { zone, type: kind, policy };
		let mode = read_value(fs, `${dir}/mode`);
		let passive = read_value(fs, `${dir}/passive`);

		if (mode != null)
			labels.mode = mode;
		if (passive != null && match(passive, INTEGER))
			labels.passive = passive;

		temp(labels, int(millideg) / 1000.0);
	}

	return Result.ok();
};
