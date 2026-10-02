'use strict';

// rpcd ucode plugin of ucode-prometheus-exporter: the service's ubus object
// (prometheus_exporter.rpc), for LuCI and for `ubus call` alike. rpcd loads it
// when it starts or reloads, so it answers whether or not the exporter runs.

import { popen, stat } from 'fs';
import * as uloop from 'uloop';
import * as rpc from 'prometheus_exporter.rpc';
import { DIR } from 'prometheus_exporter.loader';

// rpcd never loads a collector module it has not seen load in a process of
// its own first: one that hangs would hang rpcd (rpc.cached_probe).
const probe = rpc.cached_probe({ stat, popen }, DIR, rpc.PROBE_HELPER);

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

return { [rpc.OBJECT]: rpc.methods((opts) => rpc.system({ ...(opts ?? {}), probe }), io) };
