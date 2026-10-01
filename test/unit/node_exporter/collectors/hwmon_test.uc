'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { glob } from 'fs';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as hwmon from 'node_exporter.collectors.hwmon';

// Every file a device has under /sys/class/hwmon, and the chips' device links.
function sysfs(device) {
	let root = `test/fixtures/${device}`;
	let paths = map(glob(`${root}/sys/class/hwmon/*/*`), (p) => substr(p, length(root)));

	return fixtures.files(device, paths);
}

function links(device) {
	return json(fixtures.file(device, '/links.json'));
}

const ROUTER = sysfs('caju-router');
const ROUTER_LINKS = links('caju-router');
const AP = sysfs('caju-ap');
const AP_LINKS = links('caju-ap');
const SYNTHETIC = { ...sysfs('synthetic'), '/sys/class/hwmon/hwmon1/name': null };
const SYNTHETIC_LINKS = links('synthetic');

// The fs mock has no symlinks: realpath answers from the recorded links.
function fs_of(data, linked, behavior) {
	return { data, behavior: { realpath: (p) => linked[p], ...(behavior ?? {}) } };
}

describe('collectors.hwmon', () => {
	it('names the caju router chips after their devices, cleaned, and reads their temperatures', () => {
		with_collector(hwmon, { fs: fs_of(ROUTER, ROUTER_LINKS) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_hwmon_chip_names Annotation metric for human-readable chip names',
				'# TYPE node_hwmon_chip_names gauge',
				'node_hwmon_chip_names{chip="thermal_thermal_zone0",chip_name="cpu_thermal"} 1',
				'node_hwmon_chip_names{chip="thermal_thermal_zone1",chip_name="gpu_thermal"} 1',
				'node_hwmon_chip_names{chip="r8169_1_1100_r8169_1_1100:00",chip_name="r8169_1_1100:00"} 1',
				'node_hwmon_chip_names{chip="r8169_2_2100_r8169_2_2100:00",chip_name="r8169_2_2100:00"} 1',
				'# HELP node_hwmon_temp_celsius Hardware monitor for temperature (input)',
				'# TYPE node_hwmon_temp_celsius gauge',
				'node_hwmon_temp_celsius{chip="thermal_thermal_zone0",sensor="temp1"} 46.666',
				'node_hwmon_temp_celsius{chip="thermal_thermal_zone1",sensor="temp1"} 47.222',
				'node_hwmon_temp_celsius{chip="r8169_1_1100_r8169_1_1100:00",sensor="temp1"} 59.5',
				'node_hwmon_temp_celsius{chip="r8169_2_2100_r8169_2_2100:00",sensor="temp1"} 60',
			], r.lines);
		});
	});

	it('names the caju AP radios ieee80211_phyN', () => {
		with_collector(hwmon, { fs: fs_of(AP, AP_LINKS) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_hwmon_chip_names Annotation metric for human-readable chip names',
				'# TYPE node_hwmon_chip_names gauge',
				'node_hwmon_chip_names{chip="thermal_thermal_zone0",chip_name="cpu_thermal"} 1',
				'node_hwmon_chip_names{chip="ieee80211_phy0",chip_name="mt7915_phy0"} 1',
				'node_hwmon_chip_names{chip="ieee80211_phy1",chip_name="mt7915_phy1"} 1',
				'# HELP node_hwmon_temp_celsius Hardware monitor for temperature (input)',
				'# TYPE node_hwmon_temp_celsius gauge',
				'node_hwmon_temp_celsius{chip="thermal_thermal_zone0",sensor="temp1"} 62.224',
				'node_hwmon_temp_celsius{chip="ieee80211_phy0",sensor="temp1"} 48',
				'node_hwmon_temp_celsius{chip="ieee80211_phy1",sensor="temp1"} 48',
			], r.lines);
		});
	});

	it('exports labels and PWM outputs, in sensor number order, and falls back to hwmonN without chip_names', () => {
		with_collector(hwmon, { fs: fs_of(SYNTHETIC, SYNTHETIC_LINKS) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_hwmon_chip_names Annotation metric for human-readable chip names',
				'# TYPE node_hwmon_chip_names gauge',
				'node_hwmon_chip_names{chip="platform_nct6775_656",chip_name="nct6779"} 1',
				'# HELP node_hwmon_sensor_label Label for given chip and sensor',
				'# TYPE node_hwmon_sensor_label gauge',
				'node_hwmon_sensor_label{chip="platform_nct6775_656",sensor="temp1",label="SYSTIN"} 1',
				'node_hwmon_sensor_label{chip="platform_nct6775_656",sensor="temp2",label="CPUTIN"} 1',
				'node_hwmon_sensor_label{chip="platform_nct6775_656",sensor="temp10",label="PCH_CPU_TEMP"} 1',
				'# HELP node_hwmon_temp_celsius Hardware monitor for temperature (input)',
				'# TYPE node_hwmon_temp_celsius gauge',
				'node_hwmon_temp_celsius{chip="platform_nct6775_656",sensor="temp1"} 32',
				'node_hwmon_temp_celsius{chip="platform_nct6775_656",sensor="temp2"} 38.5',
				'node_hwmon_temp_celsius{chip="platform_nct6775_656",sensor="temp10"} 45',
				'node_hwmon_temp_celsius{chip="hwmon1",sensor="temp1"} -5.5',
				'# HELP node_hwmon_pwm Hardware monitor pwm element ',
				'# TYPE node_hwmon_pwm gauge',
				'node_hwmon_pwm{chip="platform_nct6775_656",sensor="pwm1"} 128',
				'node_hwmon_pwm{chip="platform_nct6775_656",sensor="pwm2"} 255',
			], r.lines);
		});
	});

	it('leaves out a sensor it cannot read and keeps the others', () => {
		let unreadable = '/sys/class/hwmon/hwmon2/temp1_input';
		let behavior = { readfile: (p) => p == unreadable ? null : ROUTER[p] };

		with_collector(hwmon, { fs: fs_of(ROUTER, ROUTER_LINKS, behavior) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match(3, length(filter(r.lines, (l) => match(l, /^node_hwmon_temp_celsius\{/))));
			assert.match(false, index(r.text, 'r8169_1_1100_r8169_1_1100:00",sensor="temp1"') >= 0);
			assert.match(4, length(filter(r.lines, (l) => match(l, /^node_hwmon_chip_names\{/))));
		});
	});

	it('names a chip without a device link after its name file', () => {
		with_collector(hwmon, { fs: fs_of(ROUTER, {}) }, (r) => {
			assert.match(true, index(r.text, 'node_hwmon_chip_names{chip="cpu_thermal",chip_name="cpu_thermal"} 1') >= 0);
			assert.match(true, index(r.text, 'node_hwmon_temp_celsius{chip="cpu_thermal",sensor="temp1"} 46.666') >= 0);
		});
	});

	it('exports nothing, successfully, on a kernel without hwmon', () => {
		with_collector(hwmon, { fs: { behavior: { lsdir: () => null } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	prop('reports any millidegree reading in degrees Celsius', gen.int(-55000, 150000), (millideg) => {
		let data = {
			'/sys/class/hwmon/hwmon0/name': 'cpu_thermal\n',
			'/sys/class/hwmon/hwmon0/temp1_input': `${millideg}\n`,
		};

		with_collector(hwmon, { fs: fs_of(data, {}) }, (r) => {
			let fam = filter(r.families, (f) => f.name == 'node_hwmon_temp_celsius')[0];
			let delta = +fam.samples[0].value * 1000 - millideg;

			assert.match(true, delta > -0.001 && delta < 0.001, `${millideg} -> ${fam.samples[0].value}`);
		});
	});

	it('cleans names as node_exporter does', () => {
		assert.match([ 'r8169_1_1100:00', 'platform_nct6775_656', 'cpu_thermal', 'a_b', '' ],
			map([ 'r8169-1-1100:00', 'platform_nct6775.656', 'CPU_Thermal\n', '__a b__', '--' ], hwmon.clean));
	});

	it('tells apart chips that share a device by their name file, or else their hwmonN', () => {
		let data = {
			'/sys/class/hwmon/hwmon0/name': 'asus\n',
			'/sys/class/hwmon/hwmon1/name': 'asus_wmi_sensors\n',
			'/sys/class/hwmon/hwmon2/name': 'acpitz\n',
			'/sys/class/hwmon/hwmon3/name': 'acpitz\n',
		};
		let linked = {
			'/sys/class/hwmon/hwmon0/device': '/sys/devices/platform/asus-nb-wmi',
			'/sys/class/hwmon/hwmon1/device': '/sys/devices/platform/asus-nb-wmi',
			'/sys/class/hwmon/hwmon2/device': '/sys/devices/virtual/thermal/thermal_zone0',
			'/sys/class/hwmon/hwmon3/device': '/sys/devices/virtual/thermal/thermal_zone0',
		};

		with_collector(hwmon, { fs: fs_of(data, linked) }, (r) => {
			assert.match([
				'node_hwmon_chip_names{chip="platform_asus_nb_wmi_asus",chip_name="asus"} 1',
				'node_hwmon_chip_names{chip="platform_asus_nb_wmi_asus_wmi_sensors",chip_name="asus_wmi_sensors"} 1',
				'node_hwmon_chip_names{chip="thermal_thermal_zone0_hwmon2",chip_name="acpitz"} 1',
				'node_hwmon_chip_names{chip="thermal_thermal_zone0_hwmon3",chip_name="acpitz"} 1',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	prop('cleans any name to lowercase letters, digits, colons and inner underscores',
		gen.string({ charset: 'aZ09:_-. /', min_len: 0, max_len: 16 }), (name) => {
			let c = hwmon.clean(name);

			assert.match(true, match(c, /^([a-z0-9:]([a-z0-9:_]*[a-z0-9:])?)?$/) != null, c);
		});
});
