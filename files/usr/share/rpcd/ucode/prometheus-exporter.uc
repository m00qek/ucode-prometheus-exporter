'use strict';

import { popen, stat, lsdir, readfile, realpath } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import * as uloop from 'uloop';
import * as sources from 'prometheus.exporter.rpc.sources';
import * as plugin from 'prometheus.exporter.rpc.plugin';

const RPC = "import * as rpc from 'prometheus.exporter.rpc';\nimport { DIR } from 'prometheus.exporter.loader';\nreturn { rpc, DIR };";

const watched = {};
const probed = {};
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

function compile() {
	let m = loadstring(RPC, { raw_mode: true })();
	let probe = m.rpc.cached_probe({ stat, popen }, m.DIR, m.rpc.PROBE_HELPER, probed);

	return { object: m.rpc.OBJECT, methods: m.rpc.methods((opts) => m.rpc.system({ ...(opts ?? {}), probe }), io) };
}

return plugin.object(compile, sources.methods(sources.system(cursor, { lsdir, readfile, realpath }, connect)), uloop.timer, plugin.IDLE_SECONDS);
