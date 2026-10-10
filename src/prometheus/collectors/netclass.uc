'use strict';

import { Result, errors } from 'prometheus.exporter';

const FLAGS = /^0[xX][0-9a-fA-F]+$|^[0-9]+$/;

export const meta = {
	name: 'netclass',
	title: 'Network device properties',
	help: 'Network device properties, from rtnetlink and /sys/class/net.',
	needs: [ 'fs', 'rtnl' ],
};

const ROOT = '/sys/class/net';

const IFF_UP = 0x1;

const OPERSTATES = [ 'unknown', 'notpresent', 'down', 'lowerlayerdown', 'testing', 'dormant', 'up' ];

const PROPERTIES = [
	[ 'address_assign_type',        'gauge',   'addr_assign_type' ],
	[ 'carrier',                    'gauge',   (l) => (l.flags & IFF_UP) ? l.carrier : null ],
	[ 'carrier_changes_total',      'counter', 'carrier_changes' ],
	[ 'carrier_down_changes_total', 'counter', 'carrier_down_count' ],
	[ 'carrier_up_changes_total',   'counter', 'carrier_up_count' ],
	[ 'device_id',                  'gauge',   'dev_id' ],
	[ 'dormant',                    'gauge',   'dormant' ],
	[ 'flags',                      'gauge',   'flags' ],
	[ 'iface_id',                   'gauge',   'ifindex' ],
	[ 'iface_link',                 'gauge',   'iflink' ],
	[ 'iface_link_mode',            'gauge',   (l) => l.linkmode ],
	[ 'mtu_bytes',                  'gauge',   (l) => l.mtu ],
	[ 'name_assign_type',           'gauge',   'name_assign_type' ],
	[ 'net_dev_group',              'gauge',   (l) => l.group ],
	[ 'protocol_type',              'gauge',   (l) => l.type ],
	[ 'transmit_queue_length',      'gauge',   (l) => l.txqlen ],
];

function property(out, suffix, mtype) {
	return out[mtype](`node_network_${suffix}`, `Network device property: ${suffix}`);
}

function adminstate(flags) {
	if (flags == null || !match(trim(flags), FLAGS))
		return 'unknown';

	return (+trim(flags) & IFF_UP) ? 'up' : 'down';
}

function links(rtnl) {
	let res = rtnl.request(rtnl.const.RTM_GETLINK, rtnl.const.NLM_F_DUMP, {});

	if (!res.ok)
		return res;
	if (type(res.data) != 'array')
		return Result.err(errors.SOURCE_INVALID, `RTM_GETLINK: ${sprintf('%J', res.data)}`);

	return Result.ok(sort(filter(res.data, (l) => type(l?.dev) == 'string'),
		(a, b) => a.dev < b.dev ? -1 : 1));
}

function attr(fs, dir, name) {
	let s = fs.readfile(dir + name);

	return (s == null) ? null : split(s, '\n')[0];
}

function count(s) {
	let n = +s;

	return (type(n) == 'int' && '' + n == s) ? n : null;
}

function sysfs(fs, link) {
	let dir = `${ROOT}/${link.dev}/`;
	let up = attr(fs, dir, 'carrier_up_count'), down = attr(fs, dir, 'carrier_down_count');
	let ups = count(up), downs = count(down);
	let ifindex = attr(fs, dir, 'ifindex');
	let speed = (link.flags & IFF_UP) ? attr(fs, dir, 'speed') : null;
	let alias = link.ifalias;

	return {
		addr_assign_type: attr(fs, dir, 'addr_assign_type'),
		carrier_changes: (ups != null && downs != null) ? ups + downs : attr(fs, dir, 'carrier_changes'),
		carrier_down_count: down,
		carrier_up_count: up,
		dev_id: attr(fs, dir, 'dev_id'),
		dormant: attr(fs, dir, 'dormant'),
		duplex: (speed != null) ? attr(fs, dir, 'duplex') : null,
		flags: attr(fs, dir, 'flags'),
		ifalias: (alias == null) ? '' : split('' + alias, '\n')[0],
		ifindex,
		iflink: (link.link == null && link.link_netnsid == null) ? ifindex : attr(fs, dir, 'iflink'),
		name_assign_type: attr(fs, dir, 'name_assign_type'),
		speed,
	};
}

const FROM_DUMP = map(PROPERTIES, (p) => type(p[2]) == 'function');

export function collect(deps, out) {
	let res = links(deps.rtnl);

	if (!res.ok)
		return res;

	let up = out.gauge('node_network_up', 'Value is 1 if operstate is \'up\', 0 otherwise.');
	let info = out.gauge('node_network_info', 'Non-numeric data from /sys/class/net/<iface>, value is always 1.');
	let speed = property(out, 'speed_bytes', 'gauge');
	let families = map(PROPERTIES, (p) => property(out, p[0], p[1]));

	for (let link in res.data) {
		let device = link.dev;
		let v = sysfs(deps.fs, link);

		let labels = out.labels({ device });
		let operstate = OPERSTATES[link.operstate];
		up(labels, operstate == 'up');

		info({
			device,
			address: link.address ?? '',
			broadcast: link.broadcast ?? '',
			duplex: v.duplex,
			operstate,
			adminstate: adminstate(v.flags),
			ifalias: v.ifalias,
		}, 1);

		let mbps = int(v.speed ?? '');
		if (mbps >= 0)
			speed(labels, mbps * 125000);

		for (let i, p in PROPERTIES)
			families[i](labels, FROM_DUMP[i] ? p[2](link) : v[p[2]]);
	}

	return Result.ok();
};
