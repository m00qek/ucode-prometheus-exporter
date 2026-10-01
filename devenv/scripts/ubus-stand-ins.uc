'use strict';

// Stands in, in the pkgcheck container, for the ubus objects of services that
// do not run there, answering with a device's captured replies: procd's
// `system board` and netifd's `network.interface dump`.
// usage: ucode ubus-stand-ins.uc FIXTURE_DIR (e.g. test/fixtures/caju-router)

import { readfile } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';

function reply(name) {
	return json(readfile(`${ARGV[0]}/ubus/${name}.json`));
}

const board = reply('system.board');
const interfaces = reply('network.interface.dump');

uloop.init();
let conn = ubus.connect();
conn.publish('system', {
	board: { call: (req) => req.reply(board) },
});
conn.publish('network.interface', {
	dump: { call: (req) => req.reply(interfaces) },
});
uloop.run();
