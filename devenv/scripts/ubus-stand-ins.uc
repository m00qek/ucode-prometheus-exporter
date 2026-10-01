'use strict';

// Stands in, in the pkgcheck container, for the ubus objects of services that
// do not run there, answering with a device's captured replies: procd's
// `system board` and netifd's `network.interface dump`. With `services`,
// procd's `service list` and rpcd's `rc list` instead, for a system that runs
// no service and has no init script: run apart, so it can stop before rpcd,
// which has rc of its own, starts.
// usage: ucode ubus-stand-ins.uc FIXTURE_DIR [services] (e.g. test/fixtures/caju-router)

import { readfile } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';

function reply(name) {
	return json(readfile(`${ARGV[0]}/ubus/${name}.json`));
}

uloop.init();
let conn = ubus.connect();

if (ARGV[1] == 'services') {
	conn.publish('service', {
		list: { call: (req) => req.reply({}), args: { name: '' } },
	});
	conn.publish('rc', {
		list: { call: (req) => req.reply({}), args: { name: '', skip_running_check: true } },
	});
} else {
	const board = reply('system.board');
	const interfaces = reply('network.interface.dump');

	conn.publish('system', {
		board: { call: (req) => req.reply(board) },
	});
	conn.publish('network.interface', {
		dump: { call: (req) => req.reply(interfaces) },
	});
}

uloop.run();
