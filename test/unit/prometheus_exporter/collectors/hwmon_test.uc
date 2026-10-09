'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { glob } from 'fs';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as hwmon from 'prometheus_exporter.collectors.hwmon';

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

	it('exports labels, PWM outputs, fans, voltages, currents, power and temperature limits, in sensor number order, and falls back to hwmonN without chip_names', () => {
		with_collector(hwmon, { fs: fs_of(SYNTHETIC, SYNTHETIC_LINKS) }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_hwmon_chip_names Annotation metric for human-readable chip names',
				'# TYPE node_hwmon_chip_names gauge',
				'node_hwmon_chip_names{chip="platform_nct6775_656",chip_name="nct6779"} 1',
				'node_hwmon_chip_names{chip="i2c_0_0_0040",chip_name="ina219"} 1',
				'node_hwmon_chip_names{chip="ieee80211_phy0",chip_name="mt7915_phy0"} 1',
				'node_hwmon_chip_names{chip="i2c_1_1_0010",chip_name="lm25066"} 1',
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
				'node_hwmon_temp_celsius{chip="ieee80211_phy0",sensor="temp1"} 51',
				'# HELP node_hwmon_pwm Hardware monitor pwm element ',
				'# TYPE node_hwmon_pwm gauge',
				'node_hwmon_pwm{chip="platform_nct6775_656",sensor="pwm1"} 128',
				'node_hwmon_pwm{chip="platform_nct6775_656",sensor="pwm2"} 255',
				'# HELP node_hwmon_fan_rpm Hardware monitor for fan revolutions per minute (input)',
				'# TYPE node_hwmon_fan_rpm gauge',
				'node_hwmon_fan_rpm{chip="platform_nct6775_656",sensor="fan1"} 1205',
				'node_hwmon_fan_rpm{chip="platform_nct6775_656",sensor="fan2"} 0',
				'# HELP node_hwmon_fan_min_rpm Hardware monitor for fan revolutions per minute (min)',
				'# TYPE node_hwmon_fan_min_rpm gauge',
				'node_hwmon_fan_min_rpm{chip="platform_nct6775_656",sensor="fan1"} 0',
				'node_hwmon_fan_min_rpm{chip="platform_nct6775_656",sensor="fan2"} 300',
				'# HELP node_hwmon_fan_alarm Hardware sensor alarm status (fan)',
				'# TYPE node_hwmon_fan_alarm gauge',
				'node_hwmon_fan_alarm{chip="platform_nct6775_656",sensor="fan1"} 0',
				'node_hwmon_fan_alarm{chip="platform_nct6775_656",sensor="fan2"} 1',
				'# HELP node_hwmon_in_volts Hardware monitor for voltage (input)',
				'# TYPE node_hwmon_in_volts gauge',
				'node_hwmon_in_volts{chip="platform_nct6775_656",sensor="in0"} 1.048',
				'node_hwmon_in_volts{chip="platform_nct6775_656",sensor="in1"} 3.344',
				'node_hwmon_in_volts{chip="i2c_0_0_0040",sensor="in0"} 0.012',
				'node_hwmon_in_volts{chip="i2c_0_0_0040",sensor="in1"} 12.016',
				'node_hwmon_in_volts{chip="i2c_1_1_0010",sensor="in1"} 11.95',
				'# HELP node_hwmon_in_min_volts Hardware monitor for voltage (min)',
				'# TYPE node_hwmon_in_min_volts gauge',
				'node_hwmon_in_min_volts{chip="platform_nct6775_656",sensor="in0"} 0',
				'node_hwmon_in_min_volts{chip="platform_nct6775_656",sensor="in1"} 2.976',
				'# HELP node_hwmon_in_max_volts Hardware monitor for voltage (max)',
				'# TYPE node_hwmon_in_max_volts gauge',
				'node_hwmon_in_max_volts{chip="platform_nct6775_656",sensor="in0"} 1.744',
				'node_hwmon_in_max_volts{chip="platform_nct6775_656",sensor="in1"} 3.632',
				'# HELP node_hwmon_in_alarm Hardware sensor alarm status (in)',
				'# TYPE node_hwmon_in_alarm gauge',
				'node_hwmon_in_alarm{chip="platform_nct6775_656",sensor="in0"} 0',
				'node_hwmon_in_alarm{chip="platform_nct6775_656",sensor="in1"} 0',
				'# HELP node_hwmon_curr_amps Hardware monitor for current (input)',
				'# TYPE node_hwmon_curr_amps gauge',
				'node_hwmon_curr_amps{chip="i2c_0_0_0040",sensor="curr1"} 1.25',
				'node_hwmon_curr_amps{chip="i2c_1_1_0010",sensor="curr1"} 1.25',
				'# HELP node_hwmon_power_watt Hardware monitor for power usage in watts (input)',
				'# TYPE node_hwmon_power_watt gauge',
				'node_hwmon_power_watt{chip="i2c_0_0_0040",sensor="power1"} 15.02',
				'node_hwmon_power_watt{chip="i2c_1_1_0010",sensor="power1"} 14.94',
				'# HELP node_hwmon_power_average_watt Hardware monitor for power usage in watts (average)',
				'# TYPE node_hwmon_power_average_watt gauge',
				'node_hwmon_power_average_watt{chip="i2c_1_1_0010",sensor="power1"} 14.87',
				'# HELP node_hwmon_temp_max_celsius Hardware monitor for temperature (max)',
				'# TYPE node_hwmon_temp_max_celsius gauge',
				'node_hwmon_temp_max_celsius{chip="platform_nct6775_656",sensor="temp1"} 80',
				'node_hwmon_temp_max_celsius{chip="platform_nct6775_656",sensor="temp2"} 80',
				'node_hwmon_temp_max_celsius{chip="ieee80211_phy0",sensor="temp1"} 100',
				'# HELP node_hwmon_temp_crit_celsius Hardware monitor for temperature (crit)',
				'# TYPE node_hwmon_temp_crit_celsius gauge',
				'node_hwmon_temp_crit_celsius{chip="ieee80211_phy0",sensor="temp1"} 110',
				'# HELP node_hwmon_temp_alarm Hardware sensor alarm status (temp)',
				'# TYPE node_hwmon_temp_alarm gauge',
				'node_hwmon_temp_alarm{chip="platform_nct6775_656",sensor="temp1"} 0',
				'node_hwmon_temp_alarm{chip="platform_nct6775_656",sensor="temp2"} 0',
			], r.lines);
		});
	});

	it('reads only the files of what it exports, of one listing per chip', () => {
		let read = [];
		let behavior = {
			readfile: (p) => { push(read, p); return SYNTHETIC[p]; },
		};

		with_collector(hwmon, { fs: fs_of(SYNTHETIC, SYNTHETIC_LINKS, behavior) }, (r) => {
			let files = sort(map(filter(read, (p) => !match(p, /\/name$/)), (p) => split(p, '/')[-1]));

			assert.match(true, r.result.ok);
			assert.match([], filter(files, (f) => match(f, /^(fan1_pulses|in0_beep|pwm[0-9]_(enable|mode)|shunt_resistor|update_interval|temp[0-9]+_max_hyst|power1_(input_highest|alarm))$/)));
			assert.match(length(filter(r.lines, (l) => substr(l, 0, 1) != '#' && !match(l, /^node_hwmon_chip_names/))), length(files));
		});
	});

	it('leaves out a reading that is no integer, and one of an item it does not export', () => {
		let data = {
			'/sys/class/hwmon/hwmon0/name': 'ina3221\n',
			'/sys/class/hwmon/hwmon0/in1_input': 'n/a\n',
			'/sys/class/hwmon/hwmon0/in2_input': '5008\n',
			'/sys/class/hwmon/hwmon0/curr1_crit': '2000\n',
			'/sys/class/hwmon/hwmon0/curr1_max_alarm': '0\n',
			'/sys/class/hwmon/hwmon0/power1_input': '-1\n',
		};

		with_collector(hwmon, { fs: fs_of(data, {}) }, (r) => {
			assert.match([
				'node_hwmon_chip_names{chip="ina3221",chip_name="ina3221"} 1',
				'node_hwmon_in_volts{chip="ina3221",sensor="in2"} 5.008',
				'node_hwmon_power_watt{chip="ina3221",sensor="power1"} -1e-06',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	prop('reports millivolts, milliamperes and microwatts in volts, amperes and watts, and RPM as it is',
		gen.tuple(gen.elements('in', 'curr', 'power', 'fan'), gen.int(0, 9), gen.int(0, 100000000)), (t) => {
			let data = {
				'/sys/class/hwmon/hwmon0/name': 'chip\n',
				[`/sys/class/hwmon/hwmon0/${t[0]}${t[1]}_input`]: `${t[2]}\n`,
			};
			let per = { in: 1000, curr: 1000, power: 1000000, fan: 1 }[t[0]];

			with_collector(hwmon, { fs: fs_of(data, {}) }, (r) => {
				let fam = filter(r.families, (f) => f.name != 'node_hwmon_chip_names')[0];
				let delta = +fam.samples[0].value * per - t[2];

				assert.match(true, delta > -0.001 * per && delta < 0.001 * per, `${t[2]} -> ${fam.samples[0].value}`);
				assert.match([ [ 'chip', 'chip' ], [ 'sensor', `${t[0]}${t[1]}` ] ], fam.samples[0].labels);
			});
		});

	prop('reports any temperature limit in degrees Celsius, and an average power in watts',
		gen.tuple(gen.elements('temp1_max', 'temp1_crit', 'power1_average'), gen.int(-55000, 150000000)), (t) => {
			let data = {
				'/sys/class/hwmon/hwmon0/name': 'chip\n',
				[`/sys/class/hwmon/hwmon0/${t[0]}`]: `${t[1]}\n`,
			};
			let per = (t[0] == 'power1_average') ? 1000000 : 1000;

			with_collector(hwmon, { fs: fs_of(data, {}) }, (r) => {
				let fam = filter(r.families, (f) => f.name != 'node_hwmon_chip_names')[0];
				let delta = +fam.samples[0].value * per - t[1];

				assert.match(true, delta > -0.001 * per && delta < 0.001 * per, `${t[1]} -> ${fam.samples[0].value}`);
				assert.match({ temp1_max: 'node_hwmon_temp_max_celsius', temp1_crit: 'node_hwmon_temp_crit_celsius',
					power1_average: 'node_hwmon_power_average_watt' }[t[0]], fam.name);
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
