'use strict';

// Based on utils/prometheus-node-exporter-lua/files/usr/lib/lua/prometheus-collectors/mwan3.lua
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

import { Result, errors, services } from 'prometheus_exporter.api';

export const meta = {
	name: 'mwan3',
	title: 'mwan3 multi-WAN',
	help: 'mwan3 interface tracking, from ubus mwan3 status.',
	needs: [ 'ubus' ],
	ubus: { mwan3: [ 'status' ], rc: [ 'list' ] },
};

// What mwan3track writes to an interface's STATUS file; mwan3's rpcd plugin
// reports 'unknown' when there is none.
export const STATUSES = [ 'offline', 'online', 'disconnecting', 'connecting', 'disabled', 'notracking', 'unknown' ];

// Every value is a reading of now, so every family is a gauge (the Lua exporter
// declared the times and the probe counts counters, but they go back to 0),
// and the times are named in seconds.
//
// mwan3's ubus object is rpcd's plugin, which answers whether mwan3 runs or
// not: so whether its init script is enabled is asked first. Disabled, mwan3
// is nothing to observe; enabled and stopped, its interfaces say so
// (mwan3_interface_running 0).
export function collect(deps, out) {
	let idle = services.idle(deps.ubus, 'mwan3');

	if (idle)
		return Result.none(idle);

	let res = deps.ubus.call('mwan3', 'status', { section: 'interfaces' });

	if (!res.ok)
		return res;

	let interfaces = res.data?.interfaces;
	if (type(interfaces) != 'object')
		return Result.err(errors.SOURCE_INVALID, 'mwan3 status: no interfaces');

	let age = out.gauge('mwan3_interface_age_seconds', 'Seconds since mwan3track last checked the interface.');
	let online = out.gauge('mwan3_interface_online_seconds', 'Seconds the interface has been online; 0 when not.');
	let offline = out.gauge('mwan3_interface_offline_seconds', 'Seconds the interface has been offline; 0 when not.');
	let uptime = out.gauge('mwan3_interface_uptime_seconds', 'Seconds the network interface has been up.');
	let score = out.gauge('mwan3_interface_score', 'The tracking score of the interface.');
	let lost = out.gauge('mwan3_interface_lost', 'Tracking probes lost in the current check.');
	let turn = out.gauge('mwan3_interface_turn', 'Tracking rounds in the current check.');
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
