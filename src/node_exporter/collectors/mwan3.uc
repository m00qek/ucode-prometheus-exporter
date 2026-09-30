'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/mwan3.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const meta = {
	name: 'mwan3',
	help: 'mwan3 interface tracking, from ubus mwan3 status.',
	needs: [ 'ubus' ],
};

// What mwan3track writes to an interface's STATUS file; mwan3's rpcd plugin
// reports 'unknown' when there is none.
export const STATUSES = [ 'offline', 'online', 'disconnecting', 'connecting', 'disabled', 'notracking', 'unknown' ];

// Types as the Lua exporter declared them, so the series stay the same.
export function collect(deps, out) {
	let res = deps.ubus.call('mwan3', 'status', { section: 'interfaces' });

	if (!res.ok)
		return res;

	let interfaces = res.data?.interfaces;
	if (type(interfaces) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'mwan3 status: no interfaces');

	let age = out.counter('mwan3_interface_age', 'Seconds since mwan3track last checked the interface.');
	let online = out.counter('mwan3_interface_online', 'Seconds the interface has been online; 0 when not.');
	let offline = out.counter('mwan3_interface_offline', 'Seconds the interface has been offline; 0 when not.');
	let uptime = out.counter('mwan3_interface_uptime', 'Seconds the network interface has been up.');
	let score = out.gauge('mwan3_interface_score', 'The tracking score of the interface.');
	let lost = out.counter('mwan3_interface_lost', 'Tracking probes lost in the current check.');
	let turn = out.counter('mwan3_interface_turn', 'Tracking rounds in the current check.');
	let status = out.gauge('mwan3_interface_status', 'The tracking status of the interface: 1 for the current one.');
	let enabled = out.gauge('mwan3_interface_enabled', 'Whether the interface is enabled in mwan3.');
	let running = out.gauge('mwan3_interface_running', 'Whether mwan3track is tracking the interface.');
	let up = out.gauge('mwan3_interface_up', 'Whether the network interface is up.');

	for (let iface, d in interfaces) {
		if (type(d) != 'object')
			continue;

		let labels = { interface: iface };
		age(labels, d.age);
		online(labels, d.online);
		offline(labels, d.offline);
		uptime(labels, d.uptime);
		score(labels, d.score);
		lost(labels, d.lost);
		turn(labels, d.turn);

		// A status mwan3 adds later counts as unknown: one series is always 1.
		let current = d.status in STATUSES ? d.status : 'unknown';
		for (let s in STATUSES)
			status({ interface: iface, status: s }, s == current);

		enabled(labels, !!d.enabled);
		running(labels, !!d.running);
		up(labels, !!d.up);
	}

	return Result.ok();
};
