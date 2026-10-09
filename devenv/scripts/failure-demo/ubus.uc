'use strict';

// make failure-demo's stand-ins for the ubus objects of the services a
// container does not run: procd's `system board` and `service list`, and
// dnsmasq's `metrics`, with a router's captured replies; odhcpd's `dhcp
// ipv4leases` and `ipv6leases`, no lease; netifd's `network.interface dump`,
// a router's too, `network.device status`, the container's links, and
// `network.wireless status`, a router without radios.
// rpcd, which runs, has rc, file and luci. With `hung`, network.wireless and
// dnsmasq are left to hung.uc.
// usage: ucode ubus.uc FIXTURE_DIR [hung] (e.g. test/fixtures/caju-router)

import { readfile, lsdir } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';

function reply(name) {
	return json(readfile(`${ARGV[0]}/ubus/${name}.json`));
}

const board = reply('system.board');
const interfaces = reply('network.interface.dump');
const metrics = reply('dnsmasq.metrics');
const devices = {};

for (let name in lsdir('/sys/class/net') ?? [])
	devices[name] = { up: true, present: true };

uloop.init();
let conn = ubus.connect();

conn.publish('system', {
	board: { call: (req) => req.reply(board) },
});
conn.publish('service', {
	list: { call: (req) => req.reply({}), args: { name: '' } },
});
conn.publish('network.interface', {
	dump: { call: (req) => req.reply(interfaces) },
});
conn.publish('dhcp', {
	ipv4leases: { call: (req) => req.reply({ device: {} }) },
	ipv6leases: { call: (req) => req.reply({ device: {} }) },
});
conn.publish('network.device', {
	status: { call: (req) => req.reply(devices), args: { name: '' } },
});

if (ARGV[1] != 'hung') {
	conn.publish('network.wireless', {
		status: { call: (req) => req.reply({}) },
	});
	conn.publish('dnsmasq', {
		metrics: { call: (req) => req.reply(metrics) },
	});
}

uloop.run();
