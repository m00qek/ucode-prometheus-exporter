'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/realtek-poe.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, services } from 'prometheus_exporter.api';

export const meta = {
	name: 'realtek-poe',
	title: 'Realtek PoE',
	help: 'PoE budget, consumption and port states of realtek-poe switches, from ubus poe info.',
	needs: [ 'ubus' ],
};

// The port modes and states realtek-poe reports (src/main.c,
// poe_reply_port_ext_config and port_short_status_to_str).
export const MODES = [ 'PoE', 'Legacy', 'pre-PoE+', 'PoE+' ];
export const STATES = [ 'Disabled', 'Searching', 'Delivering power', 'Fault', 'Other fault', 'Requesting power' ];

// A device without a realtek-poe switch, where nothing publishes the `poe`
// ubus object, has nothing to observe.
export function collect(deps, out) {
	let res = deps.ubus.call('poe', 'info');

	if (services.object_missing(res))
		return Result.none('no PoE switch (no poe on ubus)');
	if (!res.ok)
		return res;

	let info = res.data;
	if (type(info) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'poe info: not an object');

	out.gauge('realtek_poe_switch_info', 'The PoE controller and its firmware.')(
		{ mcu: info.mcu, firmware: info.firmware }, 1);
	out.gauge('realtek_poe_switch_budget_watts', 'The PoE power budget.')(null, info.budget);
	out.gauge('realtek_poe_switch_consumption_watts', 'The power the ports draw.')(null, info.consumption);

	let ports = type(info.ports) == 'object' ? info.ports : {};
	let names = keys(ports);

	let priority = out.gauge('realtek_poe_port_priority', 'The PoE priority of a port.');
	for (let p in names)
		priority({ device: p }, ports[p]?.priority);

	// realtek-poe leaves the consumption out for a port that draws nothing.
	let consumption = out.gauge('realtek_poe_port_consumption_watts', 'The power a port draws.');
	for (let p in names)
		consumption({ device: p }, ports[p]?.consumption ?? 0);

	let state = out.gauge('realtek_poe_port_state', 'The PoE state of a port: 1 for the current one.');
	for (let s in STATES)
		for (let p in names)
			state({ device: p, state: s }, ports[p]?.status == s);

	let mode = out.gauge('realtek_poe_port_mode', 'The PoE mode of a port: 1 for the current one.');
	for (let m in MODES)
		for (let p in names)
			mode({ device: p, mode: m }, ports[p]?.mode == m);

	return Result.ok();
};
