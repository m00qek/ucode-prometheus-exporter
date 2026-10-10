'use strict';

import { Result, errors } from 'prometheus_exporter.api';

export const meta = {
	name: 'openwrt_interfaces',
	title: 'OpenWrt interfaces',
	help: 'OpenWrt logical interfaces (wan, lan, ...): state, uptime, devices and address counts, from netifd over ubus.',
	needs: [ 'ubus' ],
	ubus: { 'network.interface': [ 'dump' ] },
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
