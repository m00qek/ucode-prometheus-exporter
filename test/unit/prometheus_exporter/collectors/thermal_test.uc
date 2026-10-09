'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import * as fixtures from 'lib.fixtures';
import { with_collector } from 'context';
import * as thermal from 'prometheus_exporter.collectors.thermal';

const ATTRS = [ 'type', 'policy', 'temp', 'mode', 'passive' ];

// A device's thermal zones: the attributes it has, and null for those it lacks.
function zones(device, n) {
	let data = {};

	for (let z = 0; z < n; z++)
		for (let a in ATTRS) {
			let path = `/sys/class/thermal/thermal_zone${z}/${a}`;
			data[path] = (a == 'passive') ? null : fixtures.file(device, path);
		}

	return data;
}

const ROUTER = zones('caju-router', 2);
const AP = zones('caju-ap', 1);

function zone(n, attrs) {
	let data = {};

	for (let a in ATTRS)
		data[`/sys/class/thermal/thermal_zone${n}/${a}`] = attrs[a] != null ? `${attrs[a]}\n` : null;

	return data;
}

describe('collectors.thermal', () => {
	it('exports the caju router CPU and GPU zones', () => {
		with_collector(thermal, { fs: { data: ROUTER } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_thermal_zone_temp Zone temperature in Celsius',
				'# TYPE node_thermal_zone_temp gauge',
				'node_thermal_zone_temp{zone="0",type="cpu-thermal"} 46.666',
				'node_thermal_zone_temp{zone="1",type="gpu-thermal"} 47.222',
				'# HELP node_thermal_zone_info A thermal zone, by its policy and mode.',
				'# TYPE node_thermal_zone_info gauge',
				'node_thermal_zone_info{zone="0",type="cpu-thermal",policy="step_wise",mode="enabled"} 1',
				'node_thermal_zone_info{zone="1",type="gpu-thermal",policy="step_wise",mode="enabled"} 1',
			], r.lines);
		});
	});

	it('exports the caju AP CPU zone', () => {
		with_collector(thermal, { fs: { data: AP } }, (r) => {
			assert.match([
				'# HELP node_thermal_zone_temp Zone temperature in Celsius',
				'# TYPE node_thermal_zone_temp gauge',
				'node_thermal_zone_temp{zone="0",type="cpu-thermal"} 62.224',
				'# HELP node_thermal_zone_info A thermal zone, by its policy and mode.',
				'# TYPE node_thermal_zone_info gauge',
				'node_thermal_zone_info{zone="0",type="cpu-thermal",policy="step_wise",mode="enabled"} 1',
			], r.lines);
		});
	});

	it('exports a passive trip point in Celsius and leaves out a mode the zone lacks', () => {
		let data = zone(0, { type: 'acpitz', policy: 'step_wise', temp: '-2500', passive: '95000' });

		with_collector(thermal, { fs: { data } }, (r) => {
			assert.match([
				'# HELP node_thermal_zone_temp Zone temperature in Celsius',
				'# TYPE node_thermal_zone_temp gauge',
				'node_thermal_zone_temp{zone="0",type="acpitz"} -2.5',
				'# HELP node_thermal_zone_info A thermal zone, by its policy and mode.',
				'# TYPE node_thermal_zone_info gauge',
				'node_thermal_zone_info{zone="0",type="acpitz",policy="step_wise"} 1',
				'# HELP node_thermal_zone_passive_celsius Passive trip point of the zone, in Celsius.',
				'# TYPE node_thermal_zone_passive_celsius gauge',
				'node_thermal_zone_passive_celsius{zone="0",type="acpitz"} 95',
			], r.lines);
		});
	});

	it('skips a zone it cannot read and reports the rest in zone order', () => {
		let data = {
			...zone(0, { type: 'cpu-thermal', policy: 'step_wise', temp: '40000', mode: 'enabled' }),
			...zone(1, { type: 'ath10k_hwmon', policy: 'step_wise', mode: 'enabled' }),
			...zone(2, { type: 'gpu-thermal', policy: 'step_wise', temp: '41000', mode: 'enabled' }),
			...zone(10, { type: 'ddr-thermal', policy: 'user_space', temp: '42000', mode: 'disabled' }),
		};

		with_collector(thermal, { fs: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_thermal_zone_temp Zone temperature in Celsius',
				'# TYPE node_thermal_zone_temp gauge',
				'node_thermal_zone_temp{zone="0",type="cpu-thermal"} 40',
				'node_thermal_zone_temp{zone="2",type="gpu-thermal"} 41',
				'node_thermal_zone_temp{zone="10",type="ddr-thermal"} 42',
				'# HELP node_thermal_zone_info A thermal zone, by its policy and mode.',
				'# TYPE node_thermal_zone_info gauge',
				'node_thermal_zone_info{zone="0",type="cpu-thermal",policy="step_wise",mode="enabled"} 1',
				'node_thermal_zone_info{zone="2",type="gpu-thermal",policy="step_wise",mode="enabled"} 1',
				'node_thermal_zone_info{zone="10",type="ddr-thermal",policy="user_space",mode="disabled"} 1',
			], r.lines);
		});
	});

	it('exports the cooling devices of the synthetic board, by number and type, as node_exporter', () => {
		let paths = [];

		for (let n in [ 0, 1, 2 ])
			for (let a in [ 'type', 'cur_state', 'max_state' ])
				push(paths, `/sys/class/thermal/cooling_device${n}/${a}`);

		let data = fixtures.files('synthetic', paths);

		with_collector(thermal, { fs: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_cooling_device_cur_state Current throttle state of the cooling device',
				'# TYPE node_cooling_device_cur_state gauge',
				'node_cooling_device_cur_state{name="0",type="cpufreq-cpu0"} 0',
				'node_cooling_device_cur_state{name="1",type="pwm-fan"} 1',
				'node_cooling_device_cur_state{name="2",type="phy0"} 0',
				'# HELP node_cooling_device_max_state Maximum throttle state of the cooling device',
				'# TYPE node_cooling_device_max_state gauge',
				'node_cooling_device_max_state{name="0",type="cpufreq-cpu0"} 3',
				'node_cooling_device_max_state{name="1",type="pwm-fan"} 4',
				'node_cooling_device_max_state{name="2",type="phy0"} 99',
			], r.lines);
		});
	});

	it('writes zones and cooling devices together, devices in number order, and leaves out what it cannot read', () => {
		let data = {
			...zone(0, { type: 'cpu-thermal', policy: 'step_wise', temp: '40000', mode: 'enabled' }),
			'/sys/class/thermal/cooling_device10/type': 'pwm-fan\n',
			'/sys/class/thermal/cooling_device10/cur_state': '2\n',
			'/sys/class/thermal/cooling_device10/max_state': '4\n',
			'/sys/class/thermal/cooling_device2/type': 'phy1\n',
			'/sys/class/thermal/cooling_device2/cur_state': null,
			'/sys/class/thermal/cooling_device2/max_state': '99\n',
			'/sys/class/thermal/cooling_device3/type': null,
			'/sys/class/thermal/cooling_device3/cur_state': '1\n',
			'/sys/class/thermal/cooling_device3/max_state': '1\n',
		};

		with_collector(thermal, { fs: { data } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_thermal_zone_temp{zone="0",type="cpu-thermal"} 40',
				'node_thermal_zone_info{zone="0",type="cpu-thermal",policy="step_wise",mode="enabled"} 1',
				'node_cooling_device_cur_state{name="10",type="pwm-fan"} 2',
				'node_cooling_device_max_state{name="2",type="phy1"} 99',
				'node_cooling_device_max_state{name="10",type="pwm-fan"} 4',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	prop('exports any cooling device state as it is', gen.tuple(gen.int(0, 1000), gen.int(0, 1000)), (t) => {
		let data = {
			'/sys/class/thermal/cooling_device0/type': 'Processor\n',
			'/sys/class/thermal/cooling_device0/cur_state': `${t[0]}\n`,
			'/sys/class/thermal/cooling_device0/max_state': `${t[1]}\n`,
		};

		with_collector(thermal, { fs: { data } }, (r) => {
			assert.match([
				`node_cooling_device_cur_state{name="0",type="Processor"} ${t[0]}`,
				`node_cooling_device_max_state{name="0",type="Processor"} ${t[1]}`,
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('exports nothing, successfully, without thermal zones', () => {
		with_collector(thermal, { fs: { behavior: { lsdir: () => null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	prop('reports any millidegree reading in degrees Celsius', gen.int(-40000, 125000), (millideg) => {
		let data = zone(0, { type: 'cpu-thermal', policy: 'step_wise', temp: millideg });

		with_collector(thermal, { fs: { data } }, (r) => {
			let delta = +r.families[0].samples[0].value * 1000 - millideg;

			assert.match(true, delta > -0.001 && delta < 0.001, `${millideg} -> ${r.families[0].samples[0].value}`);
		});
	});

	prop('reports any passive trip point in degrees Celsius', gen.int(0, 125000), (millideg) => {
		let data = zone(0, { type: 'acpitz', policy: 'step_wise', temp: 40000, passive: millideg });

		with_collector(thermal, { fs: { data } }, (r) => {
			let fam = filter(r.families, (f) => f.name == 'node_thermal_zone_passive_celsius')[0];
			let delta = +fam.samples[0].value * 1000 - millideg;

			assert.match(true, delta > -0.001 && delta < 0.001, `${millideg} -> ${fam.samples[0].value}`);
		});
	});
});
