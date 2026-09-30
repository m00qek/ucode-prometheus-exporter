'use strict';

// Stands in for procd's `system` ubus object in the pkgcheck container, where
// procd does not run: `board` answers the reply in ARGV[0], a captured fixture.

import { readfile } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';

const board = json(readfile(ARGV[0]));

uloop.init();
let conn = ubus.connect();
conn.publish('system', {
	board: { call: (req) => req.reply(board) },
});
uloop.run();
