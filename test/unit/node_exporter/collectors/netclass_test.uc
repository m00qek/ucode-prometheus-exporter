'use strict';

import { describe, it, prop, gen, assert, contains } from 'utest';
import { readfile } from 'fs';
import { with_collector } from 'context';
import * as fixtures from 'lib.fixtures';
import * as netclass from 'node_exporter.collectors.netclass';

// The sysfs attributes netclass reads; the rest come from the link dump.
const SYSFS = [ 'addr_assign_type', 'carrier_changes', 'carrier_down_count', 'carrier_up_count', 'dev_id',
	'dormant', 'duplex', 'flags', 'ifalias', 'ifindex', 'iflink', 'name_assign_type', 'speed' ];

function sysfs_file(host, dev, attr) {
	return readfile(`test/fixtures/${host}/sys/class/net/${dev}/${attr}`);
}

// A device's captured link dump and sysfs, of the named devices only when given.
// A file the capture lacks is null: the device has none, or the kernel refused it.
function capture(host, devices) {
	let links = json(fixtures.file(host, '/rtnl/RTM_GETLINK.json'));
	let data = {};

	if (devices)
		links = filter(links, (l) => l.dev in devices);

	for (let l in links)
		for (let attr in SYSFS)
			data[`/sys/class/net/${l.dev}/${attr}`] = sysfs_file(host, l.dev, attr);

	return { links, data };
}

function cfg_of(c) {
	return { fs: { data: c.data }, rtnl: { data: { RTM_GETLINK: c.links } } };
}

// One made-up link, with these sysfs files and no others.
function one_link(link, files) {
	let data = {};

	for (let attr in SYSFS)
		data[`/sys/class/net/${link.dev}/${attr}`] = files?.[attr];

	return { links: [ link ], data };
}

const ETH9 = { dev: 'eth9', type: 1, flags: 69699, address: '02:00:00:00:09:09', broadcast: 'ff:ff:ff:ff:ff:ff',
	txqlen: 1000, mtu: 1500, carrier: true, linkmode: 0, operstate: 6, group: 0 };

const ROUTER = capture('caju-router');
const ROUTER_TWO = capture('caju-router', [ 'eth0', 'wg_mesh' ]);
const AP = capture('caju-ap');

// What sysfs says of the attributes taken from the dump, for comparing the two.
function sysfs_view(host, links) {
	let lines = [];

	for (let l in links) {
		let d = l.dev;
		let f = (attr) => sysfs_file(host, d, attr) == null ? null : trim(sysfs_file(host, d, attr));
		let duplex = f('duplex');

		push(lines, `node_network_info{device="${d}",address="${f('address')}",broadcast="${f('broadcast')}"` +
			(duplex != null ? `,duplex="${duplex}"` : '') + `,operstate="${f('operstate')}",ifalias="${f('ifalias')}"} 1`);

		for (let p in [ [ 'carrier', 'carrier' ], [ 'iface_link_mode', 'link_mode' ], [ 'mtu_bytes', 'mtu' ],
				[ 'net_dev_group', 'netdev_group' ], [ 'protocol_type', 'type' ], [ 'transmit_queue_length', 'tx_queue_len' ] ])
			push(lines, `node_network_${p[0]}{device="${d}"} ${f(p[1])}`);
	}

	return lines;
}

describe('collectors.netclass', () => {
	it('exports every property of the caju router\'s eth0 and wg_mesh', () => {
		with_collector(netclass, cfg_of(ROUTER_TWO), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'# HELP node_network_info Non-numeric data from /sys/class/net/<iface>, value is always 1.',
				'# TYPE node_network_info gauge',
				'node_network_info{device="eth0",address="02:00:00:00:01:01",broadcast="ff:ff:ff:ff:ff:ff",duplex="full",operstate="up",ifalias=""} 1',
				'node_network_info{device="wg_mesh",address="",broadcast="",operstate="unknown",ifalias=""} 1',
				'# HELP node_network_speed_bytes Network device property: speed_bytes',
				'# TYPE node_network_speed_bytes gauge',
				'node_network_speed_bytes{device="eth0"} 125000000',
				'# HELP node_network_address_assign_type Network device property: address_assign_type',
				'# TYPE node_network_address_assign_type gauge',
				'node_network_address_assign_type{device="eth0"} 3',
				'node_network_address_assign_type{device="wg_mesh"} 0',
				'# HELP node_network_carrier Network device property: carrier',
				'# TYPE node_network_carrier gauge',
				'node_network_carrier{device="eth0"} 1',
				'node_network_carrier{device="wg_mesh"} 1',
				'# HELP node_network_carrier_changes_total Network device property: carrier_changes_total',
				'# TYPE node_network_carrier_changes_total counter',
				'node_network_carrier_changes_total{device="eth0"} 4',
				'node_network_carrier_changes_total{device="wg_mesh"} 0',
				'# HELP node_network_carrier_down_changes_total Network device property: carrier_down_changes_total',
				'# TYPE node_network_carrier_down_changes_total counter',
				'node_network_carrier_down_changes_total{device="eth0"} 2',
				'node_network_carrier_down_changes_total{device="wg_mesh"} 0',
				'# HELP node_network_carrier_up_changes_total Network device property: carrier_up_changes_total',
				'# TYPE node_network_carrier_up_changes_total counter',
				'node_network_carrier_up_changes_total{device="eth0"} 2',
				'node_network_carrier_up_changes_total{device="wg_mesh"} 0',
				'# HELP node_network_device_id Network device property: device_id',
				'# TYPE node_network_device_id gauge',
				'node_network_device_id{device="eth0"} 0',
				'node_network_device_id{device="wg_mesh"} 0',
				'# HELP node_network_dormant Network device property: dormant',
				'# TYPE node_network_dormant gauge',
				'node_network_dormant{device="eth0"} 0',
				'node_network_dormant{device="wg_mesh"} 0',
				'# HELP node_network_flags Network device property: flags',
				'# TYPE node_network_flags gauge',
				'node_network_flags{device="eth0"} 4099',
				'node_network_flags{device="wg_mesh"} 145',
				'# HELP node_network_iface_id Network device property: iface_id',
				'# TYPE node_network_iface_id gauge',
				'node_network_iface_id{device="eth0"} 2',
				'node_network_iface_id{device="wg_mesh"} 27',
				'# HELP node_network_iface_link Network device property: iface_link',
				'# TYPE node_network_iface_link gauge',
				'node_network_iface_link{device="eth0"} 2',
				'node_network_iface_link{device="wg_mesh"} 27',
				'# HELP node_network_iface_link_mode Network device property: iface_link_mode',
				'# TYPE node_network_iface_link_mode gauge',
				'node_network_iface_link_mode{device="eth0"} 0',
				'node_network_iface_link_mode{device="wg_mesh"} 0',
				'# HELP node_network_mtu_bytes Network device property: mtu_bytes',
				'# TYPE node_network_mtu_bytes gauge',
				'node_network_mtu_bytes{device="eth0"} 1500',
				'node_network_mtu_bytes{device="wg_mesh"} 1220',
				'# HELP node_network_name_assign_type Network device property: name_assign_type',
				'# TYPE node_network_name_assign_type gauge',
				'node_network_name_assign_type{device="eth0"} 1',
				'node_network_name_assign_type{device="wg_mesh"} 3',
				'# HELP node_network_net_dev_group Network device property: net_dev_group',
				'# TYPE node_network_net_dev_group gauge',
				'node_network_net_dev_group{device="eth0"} 0',
				'node_network_net_dev_group{device="wg_mesh"} 0',
				'# HELP node_network_protocol_type Network device property: protocol_type',
				'# TYPE node_network_protocol_type gauge',
				'node_network_protocol_type{device="eth0"} 1',
				'node_network_protocol_type{device="wg_mesh"} 65534',
				'# HELP node_network_transmit_queue_length Network device property: transmit_queue_length',
				'# TYPE node_network_transmit_queue_length gauge',
				'node_network_transmit_queue_length{device="eth0"} 1000',
				'node_network_transmit_queue_length{device="wg_mesh"} 1000',
			], r.lines);
		});
	});

	it('lists every link of the caju router, sorted by name', () => {
		with_collector(netclass, cfg_of(ROUTER), (r) => {
			assert.match(true, r.result.ok);
			assert.match([ 'eth0', 'eth1', 'ifb4eth1', 'ifb4vlan-guest', 'lan2playground', 'lo',
				'vlan-guest', 'vlan-iot', 'vlan-main', 'vlan-mgmt', 'wg_mesh' ],
				map(filter(r.lines, (l) => match(l, /^node_network_iface_id\{/)), (l) => match(l, /device="([^"]*)"/)[1]));
		});
	});

	it('gives the speed of the caju AP\'s links that have one: none for Wi-Fi or a link that is down', () => {
		with_collector(netclass, cfg_of(AP), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_network_speed_bytes{device="br-lan"} 125000000',
				'node_network_speed_bytes{device="eth0"} 312500000',
				'node_network_speed_bytes{device="vlan-guest"} 125000000',
				'node_network_speed_bytes{device="vlan-iot"} 125000000',
				'node_network_speed_bytes{device="vlan-main"} 125000000',
				'node_network_speed_bytes{device="vlan-mgmt"} 125000000',
				'node_network_speed_bytes{device="wan"} 125000000',
			], filter(r.lines, (l) => match(l, /^node_network_speed_bytes\{/)));
			assert.match(contains([
				'node_network_info{device="lan",address="02:00:00:00:02:01",broadcast="ff:ff:ff:ff:ff:ff",duplex="unknown",operstate="lowerlayerdown",ifalias=""} 1',
				'node_network_info{device="phy0-ap0",address="02:00:00:00:02:02",broadcast="ff:ff:ff:ff:ff:ff",operstate="up",ifalias=""} 1',
				'node_network_carrier{device="lan"} 0',
				'node_network_flags{device="eth0"} 4867',
				'node_network_iface_link{device="lan"} 2',
			]), r.lines);
		});
	});

	// The attributes taken from the dump, against the same devices' sysfs.
	it('says what sysfs says of the caju router and AP', () => {
		for (let host in [ 'caju-router', 'caju-ap' ]) {
			let c = host == 'caju-ap' ? AP : ROUTER;
			let expected = sysfs_view(host, c.links);

			with_collector(netclass, cfg_of(c), (r) => {
				assert.match([], filter(expected, (l) => !(l in r.lines)), host);
			});
		}
	});

	it('leaves out the carrier, speed and duplex sysfs refuses for a link that is down', () => {
		let c = one_link({ ...ETH9, flags: 4098, carrier: false, operstate: 2 },
			{ flags: '0x1002\n', ifindex: '9\n', ifalias: '\n' });

		with_collector(netclass, cfg_of(c), (r) => {
			assert.match(true, r.result.ok);
			assert.match([
				'node_network_info{device="eth9",address="02:00:00:00:09:09",broadcast="ff:ff:ff:ff:ff:ff",operstate="down",ifalias=""} 1',
				'node_network_flags{device="eth9"} 4098',
				'node_network_iface_id{device="eth9"} 9',
				'node_network_iface_link_mode{device="eth9"} 0',
				'node_network_mtu_bytes{device="eth9"} 1500',
				'node_network_net_dev_group{device="eth9"} 0',
				'node_network_protocol_type{device="eth9"} 1',
				'node_network_transmit_queue_length{device="eth9"} 1000',
			], filter(r.lines, (l) => substr(l, 0, 1) != '#'));
		});
	});

	it('writes nothing for no links', () => {
		with_collector(netclass, { rtnl: { data: { RTM_GETLINK: [] } } }, (r) => {
			assert.match(true, r.result.ok);
			assert.match([], r.lines);
		});
	});

	it('passes a failed link dump on as the collector result', () => {
		with_collector(netclass, { rtnl: { errors: { RTM_GETLINK: 'Operation not permitted' } } }, (r) => {
			assert.match({ ok: false, error: 'RTNL_FAILED', details: 'Operation not permitted' },
				{ ok: r.result.ok, error: r.result.error, details: r.result.details });
			assert.match([], r.lines);
		});
	});

	it('fails with SOURCE_INVALID for a dump that is not a list of links', () => {
		with_collector(netclass, { rtnl: { data: { RTM_GETLINK: { dev: 'eth0' } } } }, (r) => {
			assert.match('SOURCE_INVALID', r.result.error);
			assert.match([], r.lines);
		});
	});

	it('fails with NEED_MISSING where rtnl does not load', () => {
		with_collector(netclass, { no_rtnl: true }, (r) => {
			assert.match('NEED_MISSING', r.result.error);
		});
	});

	prop('gives a speed in bytes for a positive one in Mb/s, and none otherwise', gen.int(-1, 400000), (mbps) => {
		with_collector(netclass, cfg_of(one_link(ETH9, { speed: `${mbps}\n` })), (r) => {
			assert.match(mbps > 0 ? [ `node_network_speed_bytes{device="eth9"} ${mbps * 125000}` ] : [],
				filter(r.lines, (l) => match(l, /^node_network_speed_bytes\{/)));
		});
	});

	prop('reads the hex sysfs flags', gen.int(0, 0x7ffff), (flags) => {
		with_collector(netclass, cfg_of(one_link(ETH9, { flags: sprintf('0x%x\n', flags) })), (r) => {
			assert.match(contains([ `node_network_flags{device="eth9"} ${flags}` ]), r.lines);
		});
	});

	prop('gives the carrier of a link that is up only', gen.tuple(gen.int(0, 0xffff), gen.bool()), (x) => {
		let flags = x[0], carrier = x[1];

		with_collector(netclass, cfg_of(one_link({ ...ETH9, flags, carrier })), (r) => {
			assert.match((flags & 1) ? [ `node_network_carrier{device="eth9"} ${carrier ? 1 : 0}` ] : [],
				filter(r.lines, (l) => match(l, /^node_network_carrier\{/)));
		});
	});
});
