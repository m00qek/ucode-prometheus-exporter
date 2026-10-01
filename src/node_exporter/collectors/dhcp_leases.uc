'use strict';

// The active DHCP leases of the router's DHCP servers, which neither upstream
// exporter counted: dnsmasq's, from its lease file, and odhcpd's (DHCPv6, and
// DHCPv4 where odhcpd serves it), from `ubus call dhcp ipv4leases|ipv6leases`.
//
// node_openwrt_dhcp_leases{server, interface, family} counts them. `interface`
// is the logical interface (lan, guest, ...), as openwrt_interfaces names it:
// the one whose subnet holds a dnsmasq lease's address (its lease file does
// not say; the subnet is how dnsmasq picks the range), and for odhcpd the one whose
// l3 device it serves (the first in netifd's dump, for a device several
// share). A lease no up interface's subnet holds has no `interface`. odhcpd
// lists every interface it serves, so those without leases have a 0; dnsmasq
// does not, so an interface without leases has no dnsmasq series, and a
// dnsmasq without leases none at all. A lease is what each server keeps: an
// address for dnsmasq, a binding (a client's DUID and IAID, with an address
// in each of the interface's prefixes) for odhcpd's DHCPv6.
//
// The `leases` option (off by default) adds a series per lease:
// node_openwrt_dhcp_lease_info{server, interface, family, address, mac, duid,
// iaid, hostname} 1, and node_openwrt_dhcp_lease_expiry_timestamp_seconds{server,
// interface, family, address}, left out for a lease that never expires. Off, because
// each new client, and each phone with a random MAC, is a new series, and the
// names and MACs of a household's devices are more than most dashboards need.
// An odhcpd DHCPv6 lease has a series per address or delegated prefix
// (address/length).
//
// dnsmasq's lease file is /etc/config/dhcp's leasefile, /tmp/dhcp.leases by
// default (as OpenWrt's dnsmasq init script has it), for each dnsmasq
// instance; the script creates it on start, so where it is missing dnsmasq is
// not running. A device with neither a lease file nor odhcpd on ubus (an AP)
// has no DHCP server to report on: an error, as for any missing service.

import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';
import { fields } from 'node_exporter.proc';

export const meta = {
	name: 'dhcp_leases',
	help: 'Active DHCP leases of dnsmasq and odhcpd, by interface and family.',
	needs: [ 'fs', 'ubus', 'uci', 'time' ],
	options: { leases: false },
};

export const DEFAULT_LEASEFILE = '/tmp/dhcp.leases';

// odhcpd's valid time of a lease that does not expire: (uint32_t)-1.
const INFINITE = 4294967295;

// The leases of a dnsmasq lease file, as lease_update_file() (src/lease.c)
// writes it: `expiry mac address hostname client-id` for IPv4, then a
// `duid ...` line and `expiry iaid address hostname duid` for IPv6, `*` for
// what a lease lacks; expiry is a Unix time, 0 for never. The agent-info and
// vendorclass lines it may add at the end are not leases. A DUID is made plain
// hex, as odhcpd and /etc/config/dhcp write them. A string says what is wrong
// with the file.
export function parse_leasefile(text) {
	let leases = [];

	for (let i, line in split(text, '\n')) {
		let f = fields(line);

		if (!length(f) || !match(f[0], /^[0-9]+$/))
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

// Whether the first `bits` bits of two addresses (as iptoarr() gives them) agree.
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

// From netifd's dump: the subnets of the interfaces, from their addresses and
// IPv6 prefix assignments, and the interface of each l3 device.
function networks(list) {
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

				if (bytes && type(a.mask) == 'int')
					push(subnets, { interface: name, bytes, bits: a.mask });
			}
	}

	return { subnets, devices };
}

// The interface of the most specific subnet that holds the address.
function interface_of(subnets, bytes) {
	let best = null;

	for (let s in subnets)
		if (s.bits > (best?.bits ?? -1) && in_prefix(bytes, s.bytes, s.bits))
			best = s;

	return best?.interface;
}

function mac(hex) {
	return (type(hex) == 'string' && match(hex, /^[0-9a-fA-F]{12}$/))
		? join(':', map(match(lc(hex), /../g), (m) => m[0]))
		: hex;
}

function nonempty(s) {
	return (type(s) == 'string' && s != '') ? s : null;
}

// A tally of leases by { server, interface, family }, and the leases themselves.
function ledger() {
	let counts = {};
	let order = [];
	let leases = [];

	return {
		count: function(server, iface, family, n) {
			let key = join('\x1f', [ server, iface ?? '', family ]);

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

// dnsmasq's leases: false when it has no lease file, a Result for a malformed one.
function dnsmasq(deps, nets, now, book) {
	let paths = [];

	if (deps.uci.load('dhcp'))
		deps.uci.foreach('dhcp', 'dnsmasq', (s) => push(paths, nonempty(s.leasefile) ?? DEFAULT_LEASEFILE));

	let found = false;
	for (let path in uniq(paths)) {
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

			let iface = interface_of(nets.subnets, l.bytes);
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

// The leases of one odhcpd method: { device: { <l3 device>: { leases: [...] } } }
// as handle_dhcpv4_leases() and handle_dhcpv6_leases() (src/ubus.c) reply;
// `valid` is the seconds left. False when odhcpd lacks the method: ipv4leases
// is not there in odhcpd-ipv6only, OpenWrt's default. ucode's ubus puts
// libubus's status text first in a failure's message.
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

			let expiry = (type(l.valid) == 'int' && l.valid != INFINITE) ? now + l.valid : null;
			let common = {
				server: 'odhcpd', interface: iface, family,
				mac: mac(l.mac), duid: nonempty(l.duid), iaid: l.iaid, hostname: nonempty(l.hostname), expiry,
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

	let found = dnsmasq(deps, nets, now, book);
	if (Result.is(found))
		return found;

	let objects = deps.ubus.list();
	if (!objects.ok)
		return objects;

	if ('dhcp' in objects.data) {
		for (let m in [ [ 'ipv4leases', 'ipv4' ], [ 'ipv6leases', 'ipv6' ] ]) {
			let res = odhcpd(deps, m[0], m[1], nets, now, book);

			if (Result.is(res))
				return res;
		}

		found = true;
	}

	if (!found)
		return Result.err(errors.SOURCE_UNREADABLE, 'no dnsmasq lease file and no odhcpd on ubus');

	let count = out.gauge('node_openwrt_dhcp_leases', 'Active DHCP leases, by server, interface and family.');
	for (let c in book.counts())
		count(c.labels, c.n);

	if (!options.leases)
		return Result.ok();

	let info = out.gauge('node_openwrt_dhcp_lease_info', 'An active DHCP lease: its address, client and hostname.');
	let expiry = out.gauge('node_openwrt_dhcp_lease_expiry_timestamp_seconds', 'When an active DHCP lease expires, unless it never does.');
	let seen = {};

	for (let l in book.leases()) {
		let key = `${l.server} ${l.address}`;

		// The same address twice (two lease files) would be the same series twice.
		if (seen[key])
			continue;
		seen[key] = true;

		let id = { server: l.server, interface: l.interface, family: l.family, address: l.address };
		info({ ...id, mac: l.mac, duid: l.duid, iaid: l.iaid, hostname: l.hostname }, 1);
		if (l.expiry != null)
			expiry(id, l.expiry);
	}

	return Result.ok();
};
