'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector, outcome } from 'prometheus.exporter.devkit.collector';
import * as fixtures from 'lib.fixtures';
import * as realtek_poe from 'prometheus.collectors.realtek_poe';

// Neither caju device is a PoE switch. A four-port switch as realtek-poe 1.3.1
// builds `ubus call poe info` (src/main.c, ubus_poe_info_cb): firmware "v%u.%u",
// budget and consumption as doubles, and per port its priority, mode and status,
// with a consumption only for a port that draws power. The values are made up.
const INFO = fixtures.ubus('synthetic', 'poe', 'info');

function run(reply, cb) {
	with_collector(realtek_poe, { ubus: { data: { 'poe:info': reply } } }, cb);
}

describe('collectors.realtek_poe', () => {
	it('exports the budget, consumption, and the state and mode of every port', () => {
		run(INFO, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP realtek_poe_switch_info The PoE controller and its firmware.',
				'# TYPE realtek_poe_switch_info gauge',
				'realtek_poe_switch_info{mcu="Nuvoton M05xx LAN Microcontroller",firmware="v2.2"} 1',
				'# HELP realtek_poe_switch_budget_watts The PoE power budget.',
				'# TYPE realtek_poe_switch_budget_watts gauge',
				'realtek_poe_switch_budget_watts 130',
				'# HELP realtek_poe_switch_consumption_watts The power the ports draw.',
				'# TYPE realtek_poe_switch_consumption_watts gauge',
				'realtek_poe_switch_consumption_watts 12.8',
				'# HELP realtek_poe_port_priority The PoE priority of a port.',
				'# TYPE realtek_poe_port_priority gauge',
				'realtek_poe_port_priority{device="lan1"} 2',
				'realtek_poe_port_priority{device="lan2"} 2',
				'realtek_poe_port_priority{device="lan3"} 1',
				'realtek_poe_port_priority{device="lan4"} 0',
				'# HELP realtek_poe_port_consumption_watts The power a port draws.',
				'# TYPE realtek_poe_port_consumption_watts gauge',
				'realtek_poe_port_consumption_watts{device="lan1"} 7.1',
				'realtek_poe_port_consumption_watts{device="lan2"} 5.7',
				'realtek_poe_port_consumption_watts{device="lan3"} 0',
				'realtek_poe_port_consumption_watts{device="lan4"} 0',
				'# HELP realtek_poe_port_state The PoE state of a port: 1 for the current one.',
				'# TYPE realtek_poe_port_state gauge',
				'realtek_poe_port_state{device="lan1",state="Disabled"} 0',
				'realtek_poe_port_state{device="lan2",state="Disabled"} 0',
				'realtek_poe_port_state{device="lan3",state="Disabled"} 0',
				'realtek_poe_port_state{device="lan4",state="Disabled"} 1',
				'realtek_poe_port_state{device="lan1",state="Searching"} 0',
				'realtek_poe_port_state{device="lan2",state="Searching"} 0',
				'realtek_poe_port_state{device="lan3",state="Searching"} 1',
				'realtek_poe_port_state{device="lan4",state="Searching"} 0',
				'realtek_poe_port_state{device="lan1",state="Delivering power"} 1',
				'realtek_poe_port_state{device="lan2",state="Delivering power"} 1',
				'realtek_poe_port_state{device="lan3",state="Delivering power"} 0',
				'realtek_poe_port_state{device="lan4",state="Delivering power"} 0',
				'realtek_poe_port_state{device="lan1",state="Fault"} 0',
				'realtek_poe_port_state{device="lan2",state="Fault"} 0',
				'realtek_poe_port_state{device="lan3",state="Fault"} 0',
				'realtek_poe_port_state{device="lan4",state="Fault"} 0',
				'realtek_poe_port_state{device="lan1",state="Other fault"} 0',
				'realtek_poe_port_state{device="lan2",state="Other fault"} 0',
				'realtek_poe_port_state{device="lan3",state="Other fault"} 0',
				'realtek_poe_port_state{device="lan4",state="Other fault"} 0',
				'realtek_poe_port_state{device="lan1",state="Requesting power"} 0',
				'realtek_poe_port_state{device="lan2",state="Requesting power"} 0',
				'realtek_poe_port_state{device="lan3",state="Requesting power"} 0',
				'realtek_poe_port_state{device="lan4",state="Requesting power"} 0',
				'# HELP realtek_poe_port_mode The PoE mode of a port: 1 for the current one.',
				'# TYPE realtek_poe_port_mode gauge',
				'realtek_poe_port_mode{device="lan1",mode="PoE"} 0',
				'realtek_poe_port_mode{device="lan2",mode="PoE"} 1',
				'realtek_poe_port_mode{device="lan3",mode="PoE"} 0',
				'realtek_poe_port_mode{device="lan4",mode="PoE"} 0',
				'realtek_poe_port_mode{device="lan1",mode="Legacy"} 0',
				'realtek_poe_port_mode{device="lan2",mode="Legacy"} 0',
				'realtek_poe_port_mode{device="lan3",mode="Legacy"} 0',
				'realtek_poe_port_mode{device="lan4",mode="Legacy"} 0',
				'realtek_poe_port_mode{device="lan1",mode="pre-PoE+"} 0',
				'realtek_poe_port_mode{device="lan2",mode="pre-PoE+"} 0',
				'realtek_poe_port_mode{device="lan3",mode="pre-PoE+"} 0',
				'realtek_poe_port_mode{device="lan4",mode="pre-PoE+"} 0',
				'realtek_poe_port_mode{device="lan1",mode="PoE+"} 1',
				'realtek_poe_port_mode{device="lan2",mode="PoE+"} 0',
				'realtek_poe_port_mode{device="lan3",mode="PoE+"} 1',
				'realtek_poe_port_mode{device="lan4",mode="PoE+"} 1',
			], r.lines);
		});
	});

	it('exports the switch alone when it has no ports configured', () => {
		run({ firmware: 'v2.2', budget: 65.0, consumption: 0.0, ports: {} }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'realtek_poe_switch_info{firmware="v2.2"} 1',
				'realtek_poe_switch_budget_watts 65',
				'realtek_poe_switch_consumption_watts 0',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('has nothing to observe on a device without a PoE switch: no poe object', () => {
		with_collector(realtek_poe, { ubus: { errors: { 'poe:info': "Not found: Failed to resolve object name 'poe'" } } }, (r) => {
			assert.match({ ok: true, none: 'no PoE switch (no poe on ubus)', error: null, lines: [], logs: [] }, outcome(r));
		});
	});

	it('passes on any other ubus error, as a poe object that does not answer', () => {
		with_collector(realtek_poe, { ubus: { errors: { 'poe:info': 'Request timed out' } } }, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'poe info: Request timed out' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for an empty reply', () => {
		run(() => null, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
		});
	});

	prop('marks at most one state of a port, and exactly one for a state realtek-poe names',
		gen.oneof(gen.elements(...realtek_poe.STATES), gen.elements('unknown', 'Fault ')), (status) => {
			run({ budget: 65.0, ports: { lan1: { priority: 0, status } } }, (r) => {
				let on = filter(r.lines, (l) => match(l, /^realtek_poe_port_state\{.* 1$/));
				assert.match((status in realtek_poe.STATES) ? [ `realtek_poe_port_state{device="lan1",state="${status}"} 1` ] : [], on);
			});
		});
});
