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

import { Result, errors } from 'prometheus_exporter.api';

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

// A sysfs attribute's first line, or null when the kernel refuses it.
function attr(fs, dir, name) {
	let s = fs.readfile(dir + name);

	return (s == null) ? null : split(s, '\n')[0];
}

// The integer a sysfs attribute holds, as the format spells it, or null.
function count(s) {
	let n = +s;

	return (type(n) == 'int' && '' + n == s) ? n : null;
}

// The sysfs attributes of a link, by name, as reading each would give them.
// A file on a router's sysfs costs as much as all else netclass does for a
// link, so it reads 9 to 11 where reading every one is 14, and takes the
// rest from what tells the same:
//   - flags, once for the adminstate and its family;
//   - ifalias from the dump, which has it (IFLA_IFALIAS) when the link has
//     one, and sysfs an empty line when not;
//   - carrier_changes, carrier_up_count plus carrier_down_count, which is
//     what sysfs writes of it (since Linux 4.16, when they came);
//   - iflink, the link's ifindex when the dump has no IFLA_LINK, nor
//     IFLA_LINK_NETNSID for one in another namespace, whose name it cannot
//     give: the kernel leaves IFLA_LINK out when the two are the same;
//   - speed and duplex, which sysfs refuses alike, of a link not up and of
//     one whose driver cannot tell (EINVAL): duplex is read only when speed
//     could be.
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

// Whether each of PROPERTIES is the dump's, a function of the link.
const FROM_DUMP = map(PROPERTIES, (p) => type(p[2]) == 'function');

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
		let v = sysfs(deps.fs, link);

		let labels = out.labels({ device });
		let operstate = OPERSTATES[link.operstate];
		up(labels, operstate == 'up');

		// sysfs has an empty line where the device has no hardware address. The
		// adminstate is node_exporter's: IFF_UP of the sysfs flags.
		info({
			device,
			address: link.address ?? '',
			broadcast: link.broadcast ?? '',
			duplex: v.duplex,
			operstate,
			adminstate: adminstate(v.flags),
			ifalias: v.ifalias,
		}, 1);

		// Mb/s; -1 or unreadable when the link is down, which node_exporter
		// leaves out with --collector.netclass.ignore-invalid-speed (its 2.x default).
		let mbps = int(v.speed ?? '');
		if (mbps >= 0)
			speed(labels, mbps * 125000);

		for (let i, p in PROPERTIES)
			families[i](labels, FROM_DUMP[i] ? p[2](link) : v[p[2]]);
	}

	return Result.ok();
};
