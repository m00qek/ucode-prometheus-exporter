'use strict';

// Based on utils/prometheus-node-exporter-ucode/files/base/netclass.uc
// in OpenWrt's packages feed (Apache-2.0), rewritten for this exporter; see NOTICE.

// The links come from one rtnetlink dump, which also carries the attributes
// that netlink and sysfs take from the same field of the device: address,
// broadcast, operstate, mtu, type, txqlen, link_mode, group and carrier. The
// rest are in sysfs only, one file each: flags too, since netlink's are
// dev_get_flags() (IFF_RUNNING and IFF_LOWER_UP added, the promiscuity and
// allmulti counts dropped) and sysfs's the device's own. The output is what
// reading every attribute from sysfs gives.

import { Result, errors, proc } from 'prometheus_exporter.api';

// Regexes are constants: ucode compiles a regex literal each time it is evaluated.
const FLAGS = /^0[xX][0-9a-fA-F]+$|^[0-9]+$/;

export const meta = {
	name: 'netclass',
	title: 'Network device properties',
	help: 'Network device properties, from rtnetlink and /sys/class/net.',
	needs: [ 'fs', 'rtnl' ],
};

const ROOT = '/sys/class/net';

const IFF_UP = 0x1;

// IF_OPER_*, as sysfs spells them.
const OPERSTATES = [ 'unknown', 'notpresent', 'down', 'lowerlayerdown', 'testing', 'dormant', 'up' ];

// Each family: [ metric suffix, type, the value's source ], in upstream's order.
// A source is a sysfs attribute, or a function of the link from the dump.
const PROPERTIES = [
	[ 'address_assign_type',        'gauge',   'addr_assign_type' ],
	// sysfs refuses the carrier of a device that is not up (EINVAL).
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

// node_exporter's wording.
function property(out, suffix, mtype) {
	return out[mtype](`node_network_${suffix}`, `Network device property: ${suffix}`);
}

// 'up' or 'down' by IFF_UP of the sysfs flags, or 'unknown' without them.
function adminstate(flags) {
	if (flags == null || !match(trim(flags), FLAGS))
		return 'unknown';

	return (+trim(flags) & IFF_UP) ? 'up' : 'down';
}

// The links, sorted by name, or a failed Result.
function links(rtnl) {
	let res = rtnl.request(rtnl.const.RTM_GETLINK, rtnl.const.NLM_F_DUMP, {});

	if (!res.ok)
		return res;
	if (type(res.data) != 'array')
		return Result.err(errors.SOURCE_INVALID, `RTM_GETLINK: ${sprintf('%J', res.data)}`);

	return Result.ok(sort(filter(res.data, (l) => type(l?.dev) == 'string'),
		(a, b) => a.dev < b.dev ? -1 : 1));
}

// A sysfs attribute the kernel refuses (EINVAL: the speed of a link that is
// down) reads as null and is left out, as one the device does not have.
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
		let dir = `${ROOT}/${device}`;
		let sysfs = (attr) => proc.first_line(deps.fs, `${dir}/${attr}`);

		let labels = out.labels({ device });
		let operstate = OPERSTATES[link.operstate];
		up(labels, operstate == 'up');

		// sysfs has an empty line where the device has no hardware address. The
		// adminstate is node_exporter's: IFF_UP of the sysfs flags.
		info({
			device,
			address: link.address ?? '',
			broadcast: link.broadcast ?? '',
			duplex: sysfs('duplex'),
			operstate,
			adminstate: adminstate(sysfs('flags')),
			ifalias: sysfs('ifalias'),
		}, 1);

		// Mb/s; -1 or unreadable when the link is down, which node_exporter
		// leaves out with --collector.netclass.ignore-invalid-speed (its 2.x default).
		let mbps = int(sysfs('speed') ?? '');
		if (mbps >= 0)
			speed(labels, mbps * 125000);

		for (let i, p in PROPERTIES)
			families[i](labels, type(p[2]) == 'function' ? p[2](link) : sysfs(p[2]));
	}

	return Result.ok();
};
