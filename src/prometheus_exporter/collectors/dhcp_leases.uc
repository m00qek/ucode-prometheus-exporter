'use strict';

import { Result, errors, services, proc, u32 } from 'prometheus_exporter.api';

export const DEFAULT_LEASEFILE = '/tmp/dhcp.leases';

function nonempty(s) {
	return (type(s) == 'string' && s != '') ? s : null;
}

export function leasefiles(dhcp) {
	let paths = [];

	dhcp.foreach('dnsmasq', (s) => push(paths, nonempty(s.leasefile) ?? DEFAULT_LEASEFILE));

	return uniq(paths);
};

export const meta = {
	name: 'dhcp_leases',
	title: 'DHCP leases',
	help: 'Active DHCP leases of dnsmasq and odhcpd, by interface and family.',
	needs: [ 'fs', 'ubus', 'uci', 'time' ],
	ubus: { dhcp: [ 'ipv4leases', 'ipv6leases' ], 'network.interface': [ 'dump' ], rc: [ 'list' ] },
	configs: [ 'dhcp' ],
	options: {
		leases: { default: false, title: 'Lease series', help: 'A series per lease, with its address, MAC, hostname and expiry.' },
	},
	paths: [ (options, uci) => leasefiles(uci.dhcp) ],
};

const INFINITE = 4294967295;

const DIGITS = /^[0-9]+$/;

export function parse_leasefile(text) {
	let leases = [];

	for (let i, line in split(text, '\n')) {
		let f = proc.fields(line);

		if (!length(f) || !match(f[0], DIGITS))
			continue;
		if (length(f) != 5)
			return `line ${i + 1}: ${length(f)} fields, not 5`;

		let bytes = iptoarr(f[2]);
		if (!bytes)
			return `line ${i + 1}: ${sprintf('%J', f[2])} is not an address`;

		let v6 = length(bytes) == 16;
		push(leases, {
			family: v6 ? 'ipv6' : 'ipv4',
			address: f[2],
			bytes,
			expiry: +f[0],
			mac: v6 ? null : f[1],
			iaid: v6 ? f[1] : null,
			duid: (v6 && f[4] != '*') ? lc(replace(f[4], ':', '')) : null,
			hostname: f[3] != '*' ? f[3] : null,
		});
	}

	return leases;
};

export function in_prefix(addr, net, bits) {
	if (length(addr) != length(net) || bits > 8 * length(addr))
		return false;

	for (let i = 0; bits > 0; i++, bits -= 8) {
		let mask = bits >= 8 ? 0xff : (0xff << (8 - bits)) & 0xff;

		if ((addr[i] & mask) != (net[i] & mask))
			return false;
	}

	return true;
};

function word(b) {
	return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
}

export function networks(list) {
	let subnets = [];
	let devices = {};

	for (let i in list) {
		let name = i?.interface;
		if (type(name) != 'string')
			continue;

		if (type(i.l3_device) == 'string')
			devices[i.l3_device] ??= name;

		for (let key in [ 'ipv4-address', 'ipv6-address', 'ipv6-prefix-assignment' ])
			for (let a in (type(i[key]) == 'array' ? i[key] : [])) {
				let bytes = type(a?.address) == 'string' ? iptoarr(a.address) : null;

				if (bytes && type(a.mask) == 'int' && a.mask >= 0 && a.mask <= 8 * length(bytes))
					push(subnets, { interface: name, bytes, bits: a.mask, order: length(subnets) });
			}
	}

	subnets = sort(subnets, (a, b) => a.bits != b.bits ? b.bits - a.bits : a.order - b.order);

	let v4 = [], v6 = [];
	for (let s in subnets) {
		if (length(s.bytes) == 4) {
			s.mask = s.bits ? (0xffffffff << (32 - s.bits)) & 0xffffffff : 0;
			s.net = word(s.bytes) & s.mask;
			push(v4, s);
		} else {
			push(v6, s);
		}
	}

	return { v4, v6, devices };
};

export function interface_of(nets, bytes) {
	if (length(bytes) == 4) {
		let a = word(bytes);

		for (let s in nets.v4)
			if ((a & s.mask) == s.net)
				return s.interface;

		return null;
	}

	for (let s in nets.v6)
		if (in_prefix(bytes, s.bytes, s.bits))
			return s.interface;

	return null;
};

const MAC_HEX = /^[0-9a-fA-F]{12}$/;
const OCTET = /../g;

function mac(hex) {
	return (type(hex) == 'string' && match(hex, MAC_HEX))
		? join(':', map(match(lc(hex), OCTET), (m) => m[0]))
		: hex;
}

function ledger() {
	let counts = {};
	let order = [];
	let leases = [];

	return {
		count: function(server, iface, family, n) {
			let key = `${server}\x1f${iface ?? ''}\x1f${family}`;

			if (!counts[key]) {
				counts[key] = { labels: { server, interface: iface, family }, n: 0 };
				push(order, key);
			}

			counts[key].n += n;
		},

		lease: (l) => push(leases, l),
		counts: () => map(order, (k) => counts[k]),
		leases: () => leases,
	};
}

function dnsmasq(deps, nets, now, book) {
	let found = false;

	for (let path in leasefiles(deps.uci.dhcp)) {
		let text = deps.fs.readfile(path);

		if (text == null)
			continue;
		found = true;

		let leases = parse_leasefile(text);
		if (type(leases) == 'string')
			return Result.err(errors.SOURCE_INVALID, `${path}: ${leases}`);

		for (let l in leases) {
			if (l.expiry != 0 && l.expiry <= now)
				continue;

			let iface = interface_of(nets, l.bytes);
			book.count('dnsmasq', iface, l.family, 1);
			book.lease({
				server: 'dnsmasq', interface: iface, family: l.family, address: l.address,
				mac: l.mac, duid: l.duid, iaid: l.iaid, hostname: l.hostname,
				expiry: l.expiry != 0 ? l.expiry : null,
			});
		}
	}

	return found;
}

function odhcpd(deps, method, family, nets, now, book) {
	let res = deps.ubus.call('dhcp', method);

	if (!res.ok)
		return index(res.details ?? '', 'Method not found') >= 0 ? false : res;

	let devices = res.data?.device;
	if (type(devices) != 'object')
		return Result.err(errors.SOURCE_INVALID, `dhcp ${method}: no device table`);

	for (let dev, entry in devices) {
		let iface = nets.devices[dev];
		let leases = entry?.leases;

		if (type(leases) != 'array')
			return Result.err(errors.SOURCE_INVALID, `dhcp ${method}: ${dev}: no lease list`);

		book.count('odhcpd', iface, family, length(leases));

		for (let l in leases) {
			if (type(l) != 'object')
				continue;

			let valid = u32(l.valid);
			let expiry = (type(valid) == 'int' && valid != INFINITE) ? now + valid : null;
			let common = {
				server: 'odhcpd', interface: iface, family,
				mac: mac(l.mac), duid: nonempty(l.duid), iaid: u32(l.iaid), hostname: nonempty(l.hostname), expiry,
			};

			if (family == 'ipv4') {
				if (type(l.address) == 'string')
					book.lease({ ...common, address: l.address });
				continue;
			}

			for (let a in (type(l['ipv6-addr']) == 'array' ? l['ipv6-addr'] : []))
				if (type(a?.address) == 'string')
					book.lease({ ...common, address: a.address });

			for (let a in (type(l['ipv6-prefix']) == 'array' ? l['ipv6-prefix'] : []))
				if (type(a?.address) == 'string' && type(a['prefix-length']) == 'int')
					book.lease({ ...common, address: `${a.address}/${a['prefix-length']}` });
		}
	}

	return true;
}

export function collect(deps, out, options) {
	let dump = deps.ubus.call('network.interface', 'dump');
	if (!dump.ok)
		return dump;

	let nets = networks(type(dump.data?.interface) == 'array' ? dump.data.interface : []);
	let now = deps.time.now();
	let book = ledger();

	let idle = [];
	let failure = null;

	let found = dnsmasq(deps, nets, now, book);
	if (Result.is(found))
		return found;

	if (!found) {
		let files = leasefiles(deps.uci.dhcp);
		let why = length(files) ? services.idle(deps.ubus, 'dnsmasq') : 'dnsmasq has no instance';

		if (why)
			push(idle, why);
		else
			failure = Result.err(errors.SOURCE_UNREADABLE, `dnsmasq is enabled, without its lease file (${join(', ', files)})`);
	}

	let objects = deps.ubus.list();
	if (!objects.ok)
		return objects;

	if ('dhcp' in objects.data) {
		for (let m in [ [ 'ipv4leases', 'ipv4' ], [ 'ipv6leases', 'ipv6' ] ]) {
			let res = odhcpd(deps, m[0], m[1], nets, now, book);

			if (Result.is(res))
				return res;
		}
	} else {
		let why = services.idle(deps.ubus, 'odhcpd');

		if (why)
			push(idle, why);
		else
			failure ??= Result.err(errors.SOURCE_UNREADABLE, 'odhcpd is enabled, and not on ubus (dhcp)');
	}

	if (length(idle) == 2)
		return Result.none(join(', ', idle));

	let count = out.gauge('node_openwrt_dhcp_leases', 'Active DHCP leases, by server, interface and family.');
	for (let c in book.counts())
		count(c.labels, c.n);

	if (!options.leases)
		return failure ?? Result.ok();

	let info = out.gauge('node_openwrt_dhcp_lease_info', 'An active DHCP lease: its address, client and hostname.');
	let expiry = out.gauge('node_openwrt_dhcp_lease_expiry_timestamp_seconds', 'When an active DHCP lease expires, unless it never does.');
	let seen = {};

	for (let l in book.leases()) {
		let key = `${l.server} ${l.address}`;

		if (seen[key])
			continue;
		seen[key] = true;

		let id = { server: l.server, interface: l.interface, family: l.family, address: l.address };

		info({ ...id, mac: l.mac, duid: l.duid, iaid: l.iaid, hostname: l.hostname }, 1);
		if (l.expiry != null)
			expiry(id, l.expiry);
	}

	return failure ?? Result.ok();
};
