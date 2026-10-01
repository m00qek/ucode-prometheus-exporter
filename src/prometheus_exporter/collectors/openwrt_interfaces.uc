'use strict';

// OpenWrt's logical interfaces (wan, wan6, lan, ...), as netifd reports them
// in `ubus call network.interface dump` (netifd_dump_status() in its ubus.c),
// which neither upstream exporter read. node_exporter's netdev and netclass
// see kernel devices; whether "wan" is up, since when and with what address
// family is netifd's to say, and the first thing a router's dashboard asks.
//
// Every family has the label `interface`, netifd's name for it:
//
// - node_openwrt_interface_up, _pending, _available and _autostart: netifd's
//   booleans, as 0 or 1 each. A down interface with autostart 1 is one netifd
//   is failing to bring up; with autostart 0 someone took it down. pending is
//   netifd's setup state (a DHCP or PPP client still negotiating); available,
//   whether its device is there to bring it up on.
// - node_openwrt_interface_uptime_seconds: how long it has been up, only while
//   it is (netifd writes no uptime otherwise). netifd's own monotonic count:
//   a start timestamp made from it with the wall clock would move a second
//   either way from scrape to scrape, and jump with every clock step;
//   `time() - uptime` gives the timestamp where it is wanted.
// - node_openwrt_interface_info: 1, with proto, device (the configured one,
//   e.g. eth1) and l3_device (the one carrying its traffic while it is up,
//   e.g. pppoe-wan), the names node_network_*'s `device` label uses; netifd
//   leaves out those that do not apply (a wireguard interface has no device).
// - node_openwrt_interface_addresses and _routes, by family (ipv4, ipv6):
//   counts, 0 while down. Addresses themselves would be labels that change
//   with every new WAN lease, and public. An IPv6 address of a prefix
//   assignment (lan's from a delegated prefix) counts as the interface's: it
//   is one, though netifd lists it under ipv6-prefix-assignment.
// - node_openwrt_interface_ipv6_prefixes: the prefixes delegated to it (DHCPv6-PD
//   on wan6), the test of a working IPv6 uplink.
// - node_openwrt_interface_errors: the errors netifd holds for it (NO_DEVICE,
//   a protocol's failure), until it comes up again.
//
// netifd runs on every OpenWrt system, so its object missing from ubus, or the
// call failing, is an error, unlike an absent kernel feature such as nf_conntrack.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

export const meta = {
	name: 'openwrt_interfaces',
	title: 'OpenWrt interfaces',
	help: 'OpenWrt logical interfaces (wan, lan, ...): state, uptime, devices and address counts, from netifd over ubus.',
	needs: [ 'ubus' ],
};

const OBJECT = 'network.interface';

function bool(v) {
	return type(v) == 'bool' ? v : null;
}

function count(list, pred) {
	return type(list) == 'array' ? length(pred ? filter(list, pred) : list) : 0;
}

function is_v6(entry) {
	return index(entry?.target ?? '', ':') >= 0;
}

export function collect(deps, out) {
	let res = deps.ubus.call(OBJECT, 'dump');

	if (!res.ok)
		return res;

	let list = res.data?.interface;
	if (type(list) != 'array')
		return Result.err(errors.SOURCE_INVALID, `${OBJECT} dump: no interface list`);

	list = filter(list, (i) => type(i?.interface) == 'string');

	let up = out.gauge('node_openwrt_interface_up', 'Whether the logical interface is up (1) or not (0).');
	let pending = out.gauge('node_openwrt_interface_pending', 'Whether netifd is bringing the interface up (1) or not (0).');
	let available = out.gauge('node_openwrt_interface_available', 'Whether the device of the interface is there to bring it up on (1) or not (0).');
	let autostart = out.gauge('node_openwrt_interface_autostart', 'Whether netifd brings the interface up by itself (1) or not, as after ifdown (0).');
	let uptime = out.gauge('node_openwrt_interface_uptime_seconds', 'How long the interface has been up.');
	let info = out.gauge('node_openwrt_interface_info', 'The protocol and devices of a logical interface.');
	let addresses = out.gauge('node_openwrt_interface_addresses', 'The addresses of the interface, by family.');
	let routes = out.gauge('node_openwrt_interface_routes', 'The routes of the interface, by family.');
	let prefixes = out.gauge('node_openwrt_interface_ipv6_prefixes', 'The IPv6 prefixes delegated to the interface.');
	let errs = out.gauge('node_openwrt_interface_errors', 'The errors netifd holds for the interface until it is up again.');

	for (let i in list) {
		let name = out.labels({ interface: i.interface });

		up(name, bool(i.up));
		pending(name, bool(i.pending));
		available(name, bool(i.available));
		autostart(name, bool(i.autostart));

		if (i.up === true && type(i.uptime) == 'int')
			uptime(name, i.uptime);

		info({ interface: i.interface, proto: i.proto, device: i.device, l3_device: i.l3_device }, 1);

		let local6 = count(i['ipv6-prefix-assignment'], (a) => type(a?.['local-address']?.address) == 'string');
		addresses({ interface: i.interface, family: 'ipv4' }, count(i['ipv4-address']));
		addresses({ interface: i.interface, family: 'ipv6' }, count(i['ipv6-address']) + local6);

		routes({ interface: i.interface, family: 'ipv4' }, count(i.route, (r) => !is_v6(r)));
		routes({ interface: i.interface, family: 'ipv6' }, count(i.route, is_v6));

		prefixes(name, count(i['ipv6-prefix']));
		errs(name, count(i.errors));
	}

	return Result.ok();
};
