'use strict';

// The only module that touches the system. It takes each native function by
// name, so one that OpenWrt 25.12's ucode lacks fails this module's load rather
// than a scrape.
//
// modules(): the real fs, ubus, uci, rtnl, nl80211 (when installed) and clock.
// session(mods): one scrape's capabilities over module-shaped objects, the real
// ones or utest's proxies: `for(meta)` hands a collector exactly its `needs`.

import { readfile, open, lsdir, glob, stat, realpath, popen } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import * as Result from 'node_exporter.result';
import * as errors from 'node_exporter.errors';

export const NEEDS = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'exec', 'time' ];

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

export function shell_quote(arg) {
	return "'" + replace('' + arg, "'", "'\\''") + "'";
};

// run(argv): the standard output of one of the `allowed` programs, run without a
// shell's interpretation of its arguments. Its standard error is discarded.
export function exec_channel(popen_fn, allowed) {
	return {
		run: function(argv) {
			if (!(argv[0] in allowed))
				return Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]);

			let cmd = join(' ', map(argv, shell_quote));
			let p = popen_fn(cmd + ' 2>/dev/null', 'r');

			if (!p)
				return Result.err(errors.COMMAND_FAILED, `${argv[0]}: cannot start`);

			let out = p.read('all');
			let status = p.close();

			return status == 0
				? Result.ok(out)
				: Result.err(errors.COMMAND_FAILED, `${argv[0]}: exit status ${status}`);
		},
	};
};

// One scrape's capabilities: a ubus connection and a uci cursor shared by its
// collectors, and closed once it is over.
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
		case 'exec':    return exec_channel(mods.fs.popen, meta.commands ?? []);
		case 'time':    return { now: mods.time };
		}
	}

	return {
		uci: uci_cursor,

		// The deps object for a collector with this meta, or NEED_MISSING when
		// the system lacks one of its needs (nl80211 is a separate package).
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

export function modules() {
	return {
		fs: { readfile, open, lsdir, glob, stat, realpath, popen },
		ubus: { connect },
		uci: { cursor },
		rtnl: load_rtnl(),
		nl80211: load_nl80211(),
		time: () => time(),
	};
};
