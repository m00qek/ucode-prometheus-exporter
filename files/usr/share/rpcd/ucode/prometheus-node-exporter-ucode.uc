'use strict';

// rpcd ucode plugin of luci-app-prometheus-node-exporter-ucode: the exporter's
// ubus object for LuCI (node_exporter.luci.rpc). rpcd loads it when it starts or
// reloads, so it answers whether or not the exporter runs.

import { popen } from 'fs';
import * as uloop from 'uloop';
import * as rpc from 'node_exporter.luci.rpc';

// status runs its scrape in a process of its own, and rpcd's uloop says when the
// reply is there to read. Each handle is kept here until then.
const watched = {};
let next = 0;

const io = {
	popen: (command) => popen(command, 'r'),
	watch: function(handle, cb) {
		let key = `${next++}`;

		watched[key] = uloop.handle(handle, function() {
			watched[key].delete();
			delete watched[key];
			cb();
		}, uloop.ULOOP_READ);
	},
};

return { [rpc.OBJECT]: rpc.methods(rpc.system, io) };
