'use strict';

// The only module that touches the system. It takes each native function by
// name, so one that OpenWrt 25.12's ucode lacks fails this module's load rather
// than a scrape.
//
// modules(): the real fs, ubus, uci, rtnl, nl80211 and socket (these two when
// installed) and clock.
// session(mods): one scrape's capabilities over module-shaped objects, the real
// ones or utest's proxies: `for(meta)` hands a collector exactly its `needs`.

import { readfile, open, lsdir, glob, stat, realpath, popen } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const NEEDS = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket', 'exec', 'time', 'log' ];

// The functions of fs a collector may use. popen is exec's.
export const FS_API = [ 'readfile', 'open', 'lsdir', 'glob', 'stat', 'realpath' ];

// A ubus connection opened on first use, so a scrape that needs no ubus makes
// none. A null reply is not a failure by itself: only error() tells a method
// without data from a failed call.
export function ubus_channel(connect_fn) {
	let conn = null;
	let tried = false;

	function get() {
		if (!tried) {
			tried = true;
			conn = connect_fn();
		}

		return conn;
	}

	return {
		call: function(object, method, args) {
			let c = get();

			if (!c)
				return Result.err(errors.UBUS_CONNECT_FAILED);

			let reply = c.call(object, method, args ?? {});
			if (reply === null) {
				let e = c.error();
				if (e)
					return Result.err(errors.UBUS_CALL_FAILED, `${object} ${method}: ${e}`);
			}

			return Result.ok(reply);
		},

		// The names of every published object.
		list: function() {
			let c = get();

			if (!c)
				return Result.err(errors.UBUS_CONNECT_FAILED);

			let names = c.list();
			return names == null
				? Result.err(errors.UBUS_CALL_FAILED, `list: ${c.error()}`)
				: Result.ok(names);
		},

		close: function() {
			conn?.disconnect();
			conn = null;
			tried = false;
		},
	};
};

// request() of a netlink module (rtnl, nl80211) with its failures as Results,
// `code` naming them; `const` passes through.
function netlink_channel(mod, code) {
	return {
		const: mod.const,
		request: function(cmd, flags, attrs) {
			let reply = mod.request(cmd, flags, attrs);

			return reply === null && mod.error()
				? Result.err(code, mod.error())
				: Result.ok(reply);
		},
	};
}

export function nl80211_channel(mod) {
	return netlink_channel(mod, errors.NL80211_FAILED);
};

export function rtnl_channel(mod) {
	return netlink_channel(mod, errors.RTNL_FAILED);
};

// What recv() fails with (errno) once SO_RCVTIMEO passes without data: EAGAIN,
// 11 on every architecture OpenWrt builds for.
const EAGAIN = 11;

// A Unix stream socket's exchange: the message sent whole, then the reply read
// until the server closes. Every wait (connect, send, each recv) is bounded by
// `tv`; a failure is `path: <the socket module's error>`.
function exchange(mod, sock, path, message, tv, timeout_ms) {
	let failed = () => Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);

	if (!sock.setopt(mod.SOL_SOCKET, mod.SO_RCVTIMEO, tv) || !sock.setopt(mod.SOL_SOCKET, mod.SO_SNDTIMEO, tv))
		return failed();

	if (!sock.connect({ family: mod.AF_UNIX, path }))
		return failed();

	// MSG_NOSIGNAL: a server gone before the message is sent is an EPIPE, not a
	// SIGPIPE that would end uhttpd.
	for (let sent = 0; sent < length(message);) {
		let n = sock.send(substr(message, sent), mod.MSG_NOSIGNAL);

		if (n == null)
			return failed();
		sent += n;
	}

	let chunks = [];

	while (true) {
		let chunk = sock.recv(4096);

		if (chunk == null)
			return mod.error(true) == EAGAIN
				? Result.err(errors.SOCKET_FAILED, `${path}: no reply for ${timeout_ms} ms`)
				: failed();

		if (chunk == '')
			return Result.ok(join('', chunks));

		push(chunks, chunk);
	}
}

// unix_request(path, message, timeout_ms): the whole reply of the server on the
// Unix stream socket `path` to `message`, as a Result: SOCKET_FAILED when the
// socket is missing or refuses, or no more of the reply comes for timeout_ms
// (a positive integer). The socket is closed either way.
export function socket_channel(mod) {
	return {
		unix_request: function(path, message, timeout_ms) {
			if (type(timeout_ms) != 'int' || timeout_ms <= 0)
				return Result.err(errors.SOCKET_FAILED, `${path}: timeout ${timeout_ms} is not a positive number of ms`);

			let sock = mod.create(mod.AF_UNIX, mod.SOCK_STREAM);
			if (!sock)
				return Result.err(errors.SOCKET_FAILED, `${path}: ${mod.error()}`);

			let tv = { sec: timeout_ms / 1000, usec: (timeout_ms % 1000) * 1000 };
			let res = exchange(mod, sock, path, '' + message, tv, timeout_ms);

			sock.close();
			return res;
		},
	};
};

export function shell_quote(arg) {
	return "'" + replace('' + arg, "'", "'\\''") + "'";
};

// run(argv): the standard output of one of the `allowed` programs, run without a
// shell's interpretation of its arguments. Its standard error is discarded. A
// failure's data is { status }: the exit status, null when it could not start.
export function exec_channel(popen_fn, allowed) {
	return {
		run: function(argv) {
			if (!(argv[0] in allowed))
				return Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]);

			let cmd = join(' ', map(argv, shell_quote));
			let p = popen_fn(cmd + ' 2>/dev/null', 'r');

			if (!p)
				return Result.err(errors.COMMAND_FAILED, `${argv[0]}: cannot start`, { status: null });

			let out = p.read('all');
			let status = p.close();

			return status == 0
				? Result.ok(out)
				: Result.err(errors.COMMAND_FAILED, `${argv[0]}: exit status ${status}`, { status });
		},
	};
};

// One scrape's capabilities: a ubus connection and a uci cursor shared by its
// collectors, and closed once it is over. mods.log, the exporter's, takes what
// collectors log, each line naming its collector.
export function session(mods) {
	let ubus = ubus_channel(mods.ubus.connect);
	let uci = null;
	let fs = {};

	for (let name in FS_API)
		fs[name] = mods.fs[name];

	function uci_cursor() {
		uci ??= mods.uci.cursor();
		return uci;
	}

	function capability(need, meta) {
		switch (need) {
		case 'fs':      return fs;
		case 'ubus':    return ubus;
		case 'uci':     return uci_cursor();
		case 'rtnl':    return mods.rtnl ? rtnl_channel(mods.rtnl) : null;
		case 'nl80211': return mods.nl80211 ? nl80211_channel(mods.nl80211) : null;
		case 'socket':  return mods.socket ? socket_channel(mods.socket) : null;
		case 'exec':    return exec_channel(mods.fs.popen, meta.commands ?? []);
		case 'time':    return { now: mods.time };
		case 'log':     return mods.log ? (msg) => mods.log(`collector '${meta.name}': ${msg}`) : null;
		}
	}

	return {
		uci: uci_cursor,

		// The deps object for a collector with this meta, or NEED_MISSING when
		// the system lacks one of its needs (nl80211 and socket are separate
		// packages).
		for: function(meta) {
			let deps = {};

			for (let need in meta.needs) {
				let cap = capability(need, meta);

				if (cap == null)
					return Result.err(errors.NEED_MISSING, `${need} is not installed`);

				deps[need] = cap;
			}

			return Result.ok(deps);
		},

		close: () => ubus.close(),
	};
};

// A netlink module by name as well, loaded at run time: nl80211 is a separate
// package, and a module exporting `const` cannot be imported under utest (its
// generated shim does not compile). Null when it is missing or does not load:
// then only the collectors that need it fail. Lint loads both on 25.12, where a
// missing function would show.
function load_netlink(name) {
	try {
		return loadstring(
			sprintf("import { request, error, 'const' as consts } from %J;\n", name) +
			'return { request, error, const: consts };',
			{ raw_mode: true })();
	} catch (e) {
		return null;
	}
}

export function load_rtnl() {
	return load_netlink('rtnl');
};

export function load_nl80211() {
	return load_netlink('nl80211');
};

// ucode-mod-socket by name at run time too: only the collectors that need it
// (unbound) depend on its package, so a static import would stop the exporter
// loading where it is not installed. Null then. Lint loads it on 25.12.
export function load_socket() {
	try {
		return loadstring(
			"import { create, error, AF_UNIX, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL } from 'socket';\n" +
			'return { create, error, AF_UNIX, SOCK_STREAM, SOL_SOCKET, SO_RCVTIMEO, SO_SNDTIMEO, MSG_NOSIGNAL };',
			{ raw_mode: true })();
	} catch (e) {
		return null;
	}
};

export function modules() {
	return {
		fs: { readfile, open, lsdir, glob, stat, realpath, popen },
		ubus: { connect },
		uci: { cursor },
		rtnl: load_rtnl(),
		nl80211: load_nl80211(),
		socket: load_socket(),
		time: () => time(),
	};
};
