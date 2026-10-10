'use strict';

import { popen, stat } from 'fs';
import * as uloop from 'uloop';
import * as rpc from 'prometheus_exporter.rpc';
import { DIR } from 'prometheus_exporter.loader';

const probe = rpc.cached_probe({ stat, popen }, DIR, rpc.PROBE_HELPER);

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
