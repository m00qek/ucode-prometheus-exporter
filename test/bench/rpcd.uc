'use strict';

// One run of an rpcd: case, in a process of its own that holds what rpcd's
// plugin holds of the service's ubus object, and nothing of run.uc's: rpcd
// collects a plugin's garbage after every call, a pass over everything the
// plugin holds, so what it holds is what each call costs it. The sources'
// methods read the world: its wireless and network configs, its sysfs, and
// procd's `service list` from its ubus.json.
//
//   ucode -L src -L test test/bench/rpcd.uc WORLD CASE
//
// CASE is
//   rpcd:rest        what the process holds once the plugin's object is made, in kB (held_kb),
//                    this script's own few with it, and a collection of it (gc_ms)
//   rpcd:<method>    a call of a sources' method, wireless, wireguard_peers or time_daemons,
//                    and the collection rpcd makes after it; after a first call, untimed

import * as fs from 'fs';
import { cursor } from 'uci';
import * as sources from 'prometheus.exporter.rpc.sources';
import * as plugin from 'prometheus.exporter.rpc.plugin';

// What the plugin compiles of the rest of the object, as rpcd's plugin does.
const RPC = "import * as rpc from 'prometheus.exporter.rpc';\nreturn rpc;";

let world_dir = ARGV[0], name = ARGV[1];
let root = `${world_dir}/root`;
let method = split(name, ':')[1];
let replies = null;

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

function strip(p) {
	return (p != null && substr(p, 0, length(root)) == root) ? substr(p, length(root)) : p;
}

// procd's replies in the world, a call of `service list` by its name; each
// answered at once, as a deferred call is when procd answers.
function connect() {
	replies ??= json(fs.readfile(`${world_dir}/ubus.json`));

	return {
		defer: function(object, m, args, cb) {
			let reply = replies[`${object}:${m}:${args?.name}`] ?? replies[`${object}:${m}`];

			cb((reply == null) ? 4 : 0, reply);
			return {};
		},
		error: () => null,
	};
}

let sys = {
	cursor: () => cursor(`${root}/etc/config`, '/nonexistent/uci-deltas'),
	fs: {
		lsdir: (p) => fs.lsdir(root + p), readfile: (p) => fs.readfile(root + p), realpath: (p) => strip(fs.realpath(root + p)),
		stat: (p) => fs.stat(root + p),
	},
	connect,
};

function compile() {
	let rpc = loadstring(RPC, { raw_mode: true })();

	return { object: rpc.OBJECT, methods: rpc.methods(() => die('no sys here'), null) };
}

let object = plugin.object(compile, sources.methods(sys), null, plugin.IDLE_SECONDS);
let methods = object[keys(object)[0]];

gc('collect');

let result = { case: name, kind: 'rpcd', held_kb: gc('count'), ok: true };
let t = now();

gc('collect');
result.gc_ms = (now() - t) * 1000;

if (method == 'rest') {
	result.time = result.gc_ms / 1000;
} else if (methods[method] == null || !(method in keys(sources.methods(sys)))) {
	result.ok = false;
	result.error = `no method ${method} of the sources`;
} else {
	let reply = null;
	let req = { args: {}, reply: (r) => { reply = r; }, defer: () => ({}) };

	// A call before, as rpcd's first makes the connection to procd that the
	// next ones take.
	methods[method].call(req);
	reply = null;
	gc('collect');
	t = now();

	let out = methods[method].call(req);

	gc('collect');
	result.time = now() - t;
	reply ??= out;
	result.ok = type(reply) == 'object' && reply.error == null;
	result.error = result.ok ? null : sprintf('%J', reply);
}

print(sprintf('%J\n', result));
