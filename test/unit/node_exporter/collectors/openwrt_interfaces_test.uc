'use strict';

import { describe, it, prop, gen, assert } from 'utest';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as openwrt_interfaces from 'node_exporter.collectors.openwrt_interfaces';

// `ubus call network.interface dump` on each device, public addresses redacted.
const ROUTER = fixtures.ubus('caju-router', 'network.interface', 'dump');
const AP = fixtures.ubus('caju-ap', 'network.interface', 'dump');
// Down, pending, unavailable and PPPoE interfaces, IPv6 prefix delegation and
// assignment, as netifd's netifd_dump_status() (ubus.c) writes them.
const SYNTHETIC = fixtures.ubus('synthetic', 'network.interface', 'dump');

const NOT_FOUND = "Not found: Failed to resolve object name 'network.interface'";

function range(n) {
	let a = [];
	for (let i = 0; i < n; i++)
		push(a, i);
	return a;
}

function dump(reply) {
	return { ubus: { data: { 'network.interface:dump': reply } } };
}

function of_interface(lines, name) {
	return filter(lines, (l) => index(l, `interface="${name}"`) >= 0);
}

function samples(lines) {
	return filter(lines, (l) => substr(l, 0, 1) != '#');
}

describe('collectors.openwrt_interfaces', () => {
	it("describes every family of the caju router's interfaces", () => {
		with_collector(openwrt_interfaces, dump(ROUTER), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_openwrt_interface_up Whether the logical interface is up (1) or not (0).',
				'# TYPE node_openwrt_interface_up gauge',
				'# HELP node_openwrt_interface_pending Whether netifd is bringing the interface up (1) or not (0).',
				'# TYPE node_openwrt_interface_pending gauge',
				'# HELP node_openwrt_interface_available Whether the device of the interface is there to bring it up on (1) or not (0).',
				'# TYPE node_openwrt_interface_available gauge',
				'# HELP node_openwrt_interface_autostart Whether netifd brings the interface up by itself (1) or not, as after ifdown (0).',
				'# TYPE node_openwrt_interface_autostart gauge',
				'# HELP node_openwrt_interface_uptime_seconds How long the interface has been up.',
				'# TYPE node_openwrt_interface_uptime_seconds gauge',
				'# HELP node_openwrt_interface_info The protocol and devices of a logical interface.',
				'# TYPE node_openwrt_interface_info gauge',
				'# HELP node_openwrt_interface_addresses The addresses of the interface, by family.',
				'# TYPE node_openwrt_interface_addresses gauge',
				'# HELP node_openwrt_interface_routes The routes of the interface, by family.',
				'# TYPE node_openwrt_interface_routes gauge',
				'# HELP node_openwrt_interface_ipv6_prefixes The IPv6 prefixes delegated to the interface.',
				'# TYPE node_openwrt_interface_ipv6_prefixes gauge',
				'# HELP node_openwrt_interface_errors The errors netifd holds for the interface until it is up again.',
				'# TYPE node_openwrt_interface_errors gauge',
			], filter(r.lines, (l) => substr(l, 0, 1) == '#'));

			// Ten families, one series each per interface but two (a family each) for addresses and routes.
			assert.match(9 * 12, length(samples(r.lines)));
			assert.match([ 'guest', 'iot', 'lan2playground', 'loopback', 'main', 'mgmt', 'wan', 'wan6', 'wg_mesh' ],
				map(r.families[0].samples, (s) => s.labels[0][1]));
		});
	});

	it("exports the caju router's wan and wan6, on the same device", () => {
		with_collector(openwrt_interfaces, dump(ROUTER), (r) => {
			assert.match([
				'node_openwrt_interface_up{interface="wan"} 1',
				'node_openwrt_interface_pending{interface="wan"} 0',
				'node_openwrt_interface_available{interface="wan"} 1',
				'node_openwrt_interface_autostart{interface="wan"} 1',
				'node_openwrt_interface_uptime_seconds{interface="wan"} 8026',
				'node_openwrt_interface_info{interface="wan",proto="dhcp",device="eth1",l3_device="eth1"} 1',
				'node_openwrt_interface_addresses{interface="wan",family="ipv4"} 1',
				'node_openwrt_interface_addresses{interface="wan",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="wan",family="ipv4"} 1',
				'node_openwrt_interface_routes{interface="wan",family="ipv6"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="wan"} 0',
				'node_openwrt_interface_errors{interface="wan"} 0',
			], of_interface(r.lines, 'wan'));
			assert.match([
				'node_openwrt_interface_up{interface="wan6"} 1',
				'node_openwrt_interface_pending{interface="wan6"} 0',
				'node_openwrt_interface_available{interface="wan6"} 1',
				'node_openwrt_interface_autostart{interface="wan6"} 1',
				'node_openwrt_interface_uptime_seconds{interface="wan6"} 8025',
				'node_openwrt_interface_info{interface="wan6",proto="dhcpv6",device="eth1",l3_device="eth1"} 1',
				'node_openwrt_interface_addresses{interface="wan6",family="ipv4"} 0',
				'node_openwrt_interface_addresses{interface="wan6",family="ipv6"} 1',
				'node_openwrt_interface_routes{interface="wan6",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="wan6",family="ipv6"} 1',
				'node_openwrt_interface_ipv6_prefixes{interface="wan6"} 0',
				'node_openwrt_interface_errors{interface="wan6"} 0',
			], of_interface(r.lines, 'wan6'));
		});
	});

	it('leaves the device out of a wireguard interface, which has none', () => {
		with_collector(openwrt_interfaces, dump(ROUTER), (r) => {
			assert.match([
				'node_openwrt_interface_info{interface="wg_mesh",proto="wireguard",l3_device="wg_mesh"} 1',
				'node_openwrt_interface_routes{interface="wg_mesh",family="ipv4"} 3',
			], filter(of_interface(r.lines, 'wg_mesh'), (l) => match(l, /_info|routes.*ipv4/)));
		});
	});

	it("exports the caju AP's upstream, a DHCP client on its management VLAN", () => {
		with_collector(openwrt_interfaces, dump(AP), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_openwrt_interface_up{interface="upstream"} 1',
				'node_openwrt_interface_pending{interface="upstream"} 0',
				'node_openwrt_interface_available{interface="upstream"} 1',
				'node_openwrt_interface_autostart{interface="upstream"} 1',
				'node_openwrt_interface_uptime_seconds{interface="upstream"} 24387',
				'node_openwrt_interface_info{interface="upstream",proto="dhcp",device="vlan-mgmt",l3_device="vlan-mgmt"} 1',
				'node_openwrt_interface_addresses{interface="upstream",family="ipv4"} 1',
				'node_openwrt_interface_addresses{interface="upstream",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="upstream",family="ipv4"} 1',
				'node_openwrt_interface_routes{interface="upstream",family="ipv6"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="upstream"} 0',
				'node_openwrt_interface_errors{interface="upstream"} 0',
			], of_interface(r.lines, 'upstream'));
			assert.match([ 1 ], uniq(map(r.families[0].samples, (s) => +s.value)));
		});
	});

	it('tells down, pending and unavailable interfaces apart, and counts delegated and assigned IPv6', () => {
		with_collector(openwrt_interfaces, dump(SYNTHETIC), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_openwrt_interface_up{interface="guest"} 0',
				'node_openwrt_interface_up{interface="lan"} 1',
				'node_openwrt_interface_up{interface="lte"} 0',
				'node_openwrt_interface_up{interface="wan"} 1',
				'node_openwrt_interface_up{interface="wan6"} 1',
				'node_openwrt_interface_up{interface="wwan"} 0',
				'node_openwrt_interface_pending{interface="guest"} 0',
				'node_openwrt_interface_pending{interface="lan"} 0',
				'node_openwrt_interface_pending{interface="lte"} 0',
				'node_openwrt_interface_pending{interface="wan"} 0',
				'node_openwrt_interface_pending{interface="wan6"} 0',
				'node_openwrt_interface_pending{interface="wwan"} 1',
				'node_openwrt_interface_available{interface="guest"} 1',
				'node_openwrt_interface_available{interface="lan"} 1',
				'node_openwrt_interface_available{interface="lte"} 0',
				'node_openwrt_interface_available{interface="wan"} 1',
				'node_openwrt_interface_available{interface="wan6"} 1',
				'node_openwrt_interface_available{interface="wwan"} 1',
				'node_openwrt_interface_autostart{interface="guest"} 0',
				'node_openwrt_interface_autostart{interface="lan"} 1',
				'node_openwrt_interface_autostart{interface="lte"} 1',
				'node_openwrt_interface_autostart{interface="wan"} 1',
				'node_openwrt_interface_autostart{interface="wan6"} 1',
				'node_openwrt_interface_autostart{interface="wwan"} 1',
				'node_openwrt_interface_uptime_seconds{interface="lan"} 86400',
				'node_openwrt_interface_uptime_seconds{interface="wan"} 3600',
				'node_openwrt_interface_uptime_seconds{interface="wan6"} 3590',
				'node_openwrt_interface_info{interface="guest",proto="static",device="br-guest"} 1',
				'node_openwrt_interface_info{interface="lan",proto="static",device="br-lan",l3_device="br-lan"} 1',
				'node_openwrt_interface_info{interface="lte",proto="qmi",device="wwan0"} 1',
				'node_openwrt_interface_info{interface="wan",proto="pppoe",device="eth1",l3_device="pppoe-wan"} 1',
				'node_openwrt_interface_info{interface="wan6",proto="dhcpv6",device="pppoe-wan",l3_device="pppoe-wan"} 1',
				'node_openwrt_interface_info{interface="wwan",proto="dhcp",device="phy0-sta0"} 1',
				'node_openwrt_interface_addresses{interface="guest",family="ipv4"} 0',
				'node_openwrt_interface_addresses{interface="guest",family="ipv6"} 0',
				'node_openwrt_interface_addresses{interface="lan",family="ipv4"} 1',
				'node_openwrt_interface_addresses{interface="lan",family="ipv6"} 2',
				'node_openwrt_interface_addresses{interface="lte",family="ipv4"} 0',
				'node_openwrt_interface_addresses{interface="lte",family="ipv6"} 0',
				'node_openwrt_interface_addresses{interface="wan",family="ipv4"} 1',
				'node_openwrt_interface_addresses{interface="wan",family="ipv6"} 0',
				'node_openwrt_interface_addresses{interface="wan6",family="ipv4"} 0',
				'node_openwrt_interface_addresses{interface="wan6",family="ipv6"} 1',
				'node_openwrt_interface_addresses{interface="wwan",family="ipv4"} 0',
				'node_openwrt_interface_addresses{interface="wwan",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="guest",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="guest",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="lan",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="lan",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="lte",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="lte",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="wan",family="ipv4"} 1',
				'node_openwrt_interface_routes{interface="wan",family="ipv6"} 0',
				'node_openwrt_interface_routes{interface="wan6",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="wan6",family="ipv6"} 2',
				'node_openwrt_interface_routes{interface="wwan",family="ipv4"} 0',
				'node_openwrt_interface_routes{interface="wwan",family="ipv6"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="guest"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="lan"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="lte"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="wan"} 0',
				'node_openwrt_interface_ipv6_prefixes{interface="wan6"} 1',
				'node_openwrt_interface_ipv6_prefixes{interface="wwan"} 0',
				'node_openwrt_interface_errors{interface="guest"} 0',
				'node_openwrt_interface_errors{interface="lan"} 0',
				'node_openwrt_interface_errors{interface="lte"} 1',
				'node_openwrt_interface_errors{interface="wan"} 0',
				'node_openwrt_interface_errors{interface="wan6"} 0',
				'node_openwrt_interface_errors{interface="wwan"} 0',
			], samples(r.lines));
		});
	});

	it('fails without netifd on ubus, which every OpenWrt system runs', () => {
		with_collector(openwrt_interfaces, { ubus: { errors: { 'network.interface:dump': NOT_FOUND } } }, (r) => {
			assert.match([ false, 'UBUS_CALL_FAILED', [] ], [ r.result.ok, r.result.error, r.lines ]);
		});
	});

	it('passes on a failed call when netifd is on ubus', () => {
		let cfg = { ubus: { data: { 'network.interface:status': {} }, errors: { 'network.interface:dump': 'Request timed out' } } };

		with_collector(openwrt_interfaces, cfg, (r) => {
			assert.match({ ok: false, error: 'UBUS_CALL_FAILED', details: 'network.interface dump: Request timed out' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a reply without an interface list', () => {
		for (let reply in [ {}, { interface: {} }, null ])
			with_collector(openwrt_interfaces, dump(reply), (r) => {
				assert.match({ error: 'SOURCE_INVALID', details: 'network.interface dump: no interface list' },
					{ error: r.result.error, details: r.result.details });
			});
	});

	it('skips an entry without a name, and a state that is not a boolean', () => {
		with_collector(openwrt_interfaces, dump({ interface: [ { up: true }, { interface: 'x', up: 'yes', pending: false } ] }), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_openwrt_interface_pending{interface="x"} 0',
				'node_openwrt_interface_info{interface="x"} 1',
			], slice(samples(r.lines), 0, 2));
		});
	});

	prop('counts addresses and routes of each family, whatever their mix',
		gen.tuple(gen.int(0, 5), gen.int(0, 5), gen.int(0, 5), gen.array(gen.bool(), { max_len: 8 })), (t) => {
			let iface = {
				interface: 'wan', up: true, uptime: 1,
				'ipv4-address': map(range(t[0]), (n) => ({ address: `192.0.2.${n}`, mask: 32 })),
				'ipv6-address': map(range(t[1]), (n) => ({ address: `2001:db8::${n}`, mask: 128 })),
				'ipv6-prefix-assignment': map(range(t[2]), (n) => ({ address: `2001:db8:${n}::`, mask: 64, 'local-address': { address: `2001:db8:${n}::1`, mask: 64 } })),
				route: map(t[3], (v6) => v6 ? { target: '::', mask: 0 } : { target: '0.0.0.0', mask: 0 }),
			};
			let v6_routes = length(filter(t[3], (b) => b));

			with_collector(openwrt_interfaces, dump({ interface: [ iface ] }), (r) => {
				assert.match(true, r.result.ok);
				assert.match([
					`node_openwrt_interface_addresses{interface="wan",family="ipv4"} ${t[0]}`,
					`node_openwrt_interface_addresses{interface="wan",family="ipv6"} ${t[1] + t[2]}`,
					`node_openwrt_interface_routes{interface="wan",family="ipv4"} ${length(t[3]) - v6_routes}`,
					`node_openwrt_interface_routes{interface="wan",family="ipv6"} ${v6_routes}`,
				], filter(samples(r.lines), (l) => match(l, /_(addresses|routes)\{/)));
			});
		});
});

