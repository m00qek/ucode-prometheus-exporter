/**
 * The only module that touches the system, with the modules of its capabilities.
 *
 * @module prometheus_exporter_deps
 */

'use strict';

import { readfile, open, lsdir, glob, stat, lstat, realpath, popen, writefile, rename, unlink, chmod, mkstemp, stdin, access } from 'fs';
import { cursor } from 'uci';
import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as ubus_module from 'prometheus.exporter.deps.ubus';
import * as netlink_module from 'prometheus.exporter.deps.netlink';
import * as socket_module from 'prometheus.exporter.deps.socket';
import * as exec_module from 'prometheus.exporter.deps.exec';
import * as exporter_module from 'prometheus.exporter.deps.exporter';
import * as uci_module from 'prometheus.exporter.deps.uci';
import * as log_module from 'prometheus.exporter.deps.log';
import * as privileges from 'prometheus.exporter.privileges';
import { NO_UCI_DELTAS } from 'prometheus.exporter.state';

/**
 * deps.fs: the functions of the fs module a collector may use (FS_API), as the fs module has them.
 *
 * @typedef {{
 *   readfile: (path: string, limit: ?int) => ?string,
 *   open: (path: string, mode: ?string, perm: ?int) => ?FsFile,
 *   lsdir: (path: string) => ?string[],
 *   glob: (pattern: string) => ?string[],
 *   stat: (path: string) => ?FileStatResult,
 *   realpath: (path: string) => ?string
 * }} FsCapability
 */

/**
 * deps.time: the system time, in seconds.
 *
 * @typedef {{ now: () => int }} TimeCapability
 */

/**
 * What collect() gets as `deps`: one capability per entry of meta.needs.
 *
 * @typedef {{
 *   fs: FsCapability,
 *   ubus: UbusCapability,
 *   uci: Object<string, UciHandle>,
 *   rtnl: NetlinkCapability,
 *   nl80211: NetlinkCapability,
 *   socket: SocketCapability,
 *   exec: ExecCapability,
 *   time: TimeCapability,
 *   log: (msg: string) => void,
 *   exporter: ExporterCapability
 * }} Deps
 */

/**
 * One scrape's capabilities, as session() makes them.
 *
 * @typedef {{
 *   uci: () => UciCursor,
 *   for: (meta: Meta, settings: ?Settings, cutoff: ?float, view: ?ExporterView, limit: ?float) => Result<Deps>,
 *   done: () => void,
 *   close: () => void
 * }} Session
 */

/**
 * The modules a session is made over: modules()'s, or utest's proxies.
 *
 * @typedef {{
 *   fs: module:fs,
 *   ubus: { connect: function(?string, ?int): ?UbusConnection },
 *   uci: { cursor: function(): UciCursor },
 *   rtnl: ?NetlinkModule,
 *   nl80211: ?NetlinkModule,
 *   socket: ?module:socket,
 *   native: ?function(string): ?Object,
 *   time: () => int,
 *   clock: () => int[],
 *   log: ?Log,
 *   readable: ?function(string): boolean,
 *   self_status: ?function(): ?string
 * }} Modules
 */

export const ubus_channel = ubus_module.ubus_channel;
export const UBUS_TIMEOUT = ubus_module.UBUS_TIMEOUT;
export const ubus_status = ubus_module.ubus_status;

export const rtnl_channel = netlink_module.rtnl_channel;
export const nl80211_channel = netlink_module.nl80211_channel;
export const load_rtnl = netlink_module.load_rtnl;
export const load_nl80211 = netlink_module.load_nl80211;

export const socket_channel = socket_module.socket_channel;
export const load_socket = socket_module.load_socket;

export const exec_channel = exec_module.exec_channel;
export const kill_tree = exec_module.kill_tree;
export const exec_script = exec_module.exec_script;
export const batch_script = exec_module.batch_script;
export const BATCH = exec_module.BATCH;
export const shell_quote = exec_module.shell_quote;
export const EXEC_SECONDS = exec_module.EXEC_SECONDS;
export const EXEC_KILLED = exec_module.EXEC_KILLED;

export const exporter_channel = exporter_module.exporter_channel;
export const PROCESS_FILES = exporter_module.PROCESS_FILES;
export const SYSTEM_FILES = exporter_module.SYSTEM_FILES;

export const uci_handles = uci_module.uci_handles;

export const ubus_for = ubus_module.ubus_for;
export const load_ubus = ubus_module.load_ubus;

export const LEVELS = log_module.LEVELS;
export const LOG_LINES = log_module.LOG_LINES;
export const LOG_BYTES = log_module.LOG_BYTES;
export const syslog_channel = log_module.syslog_channel;
export const system_log = log_module.system_log;

/**
 * The capabilities a collector may need (meta.needs), each the name of what it gets in deps.
 *
 * @type {string[]}
 */
export const NEEDS = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket', 'exec', 'time', 'log', 'exporter' ];

/**
 * The functions of fs a collector may use.
 *
 * @type {string[]}
 */
export const FS_API = [ 'readfile', 'open', 'lsdir', 'glob', 'stat', 'realpath' ];

/**
 * Where uci's configs are, which a collector's meta.configs name.
 *
 * @type {string}
 */
export const CONFIG_DIR = '/etc/config';

/**
 * One scrape's capabilities, closed once it is over.
 *
 * @param {Modules} mods the modules: modules()'s, or utest's proxies.
 * @returns {Session} the session.
 */
export function session(mods) {
	let ubus = ubus_channel(mods.ubus.connect, mods.clock);
	let uci = null;
	let fs = {};
	let run_log = null;
	let status = null;

	for (let name in FS_API)
		fs[name] = mods.fs[name];

	function denied(meta) {
		if (length(meta.capabilities ?? []) && mods.self_status) {
			status ??= mods.self_status();

			let lack = privileges.lacking(status, meta.capabilities);

			if (length(lack))
				return `this process lacks ${join(', ', lack)}, which the service grants when it starts with ${meta.name} enabled`;
		}

		if (mods.readable)
			for (let p in [ ...map(meta.configs ?? [], (c) => `${CONFIG_DIR}/${c}`), ...(meta.proc_files ?? []) ])
				if (!mods.readable(p))
					return `${p}: the service's group may not read it, as the service has it when it starts with ${meta.name} enabled`;

		return null;
	}

	function uci_cursor() {
		uci ??= mods.uci.cursor();
		return uci;
	}

	function log_of(name) {
		let st = run_log = { name, lines: 0, left_out: 0 };

		return function(msg) {
			if (st.lines >= LOG_LINES) {
				st.left_out++;
				return;
			}

			msg = '' + msg;
			if (length(msg) > LOG_BYTES)
				msg = substr(msg, 0, LOG_BYTES) + '...';

			st.lines++;
			mods.log('warning', `collector '${name}': ${msg}`);
		};
	}

	function channel_of(need, make) {
		let mod = mods[need] ?? mods.native?.(need);

		return mod ? make(mod) : null;
	}

	function capability(need, meta, settings, cutoff, view) {
		switch (need) {
		case 'fs':      return { ...fs };
		case 'ubus':    return ubus_for(ubus, privileges.ubus_of(meta, settings?.options).ubus);
		case 'uci':     return uci_handles(uci_cursor, meta.configs ?? []);
		case 'rtnl':    return channel_of('rtnl', rtnl_channel);
		case 'nl80211': return channel_of('nl80211', nl80211_channel);
		case 'socket':  return channel_of('socket', socket_channel);
		case 'exec':    return exec_channel(mods.fs.popen, meta.commands ?? [], settings?.timeout ?? meta.timeout, mods.clock, cutoff);
		case 'time':    return { now: mods.time };
		case 'log':     return mods.log ? log_of(meta.name) : null;
		case 'exporter': return exporter_channel(mods.fs, view);
		}
	}

	return {
		uci: uci_cursor,

		for: function(meta, settings, cutoff, view, limit) {
			let deps = {};
			let why = denied(meta);

			if (why)
				return Result.err(errors.PERMISSION_DENIED, why);

			ubus.limit(limit);

			for (let need in meta.needs) {
				let cap = capability(need, meta, settings, cutoff, view);

				if (cap == null)
					return Result.err(errors.NEED_MISSING, `${need} is not installed`);

				deps[need] = cap;
			}

			return Result.ok(deps);
		},

		done: function() {
			let st = run_log;

			run_log = null;
			if (st?.left_out)
				mods.log('warning', `collector '${st.name}': ${st.left_out} more line${st.left_out == 1 ? '' : 's'} of its log left out`);
		},

		close: () => ubus.close(),
	};
};

/**
 * Where urandom reads.
 *
 * @type {string}
 */
export const RANDOM_DEVICE = '/dev/urandom';

/**
 * The kernel's random bytes: random(n) gives n of them, or null.
 *
 * @param {module:fs} fs what reads: an object of fs's open.
 * @returns {function(int): ?string} random(n).
 */
export function urandom(fs) {
	return function(n) {
		let f = fs.open(RANDOM_DEVICE, 'r');
		let bytes = f?.read(n);

		f?.close();
		return bytes;
	};
};

/**
 * A uci cursor that writes and commits, for set_password alone.
 *
 * @returns {UciCursor} the cursor.
 */
export function writable_cursor() {
	return cursor();
};

const NATIVES = {
	ubus: load_ubus,
	rtnl: load_rtnl,
	nl80211: load_nl80211,
	socket: load_socket,
};

const loaded = {};

/**
 * The native module `name`, loaded the first time it is asked for, and kept.
 *
 * @param {string} name the module's name.
 * @returns {?Object} the module; null when it does not load, or is not one of NATIVES.
 */
export function native(name) {
	if (!(name in loaded))
		loaded[name] = (name in NATIVES) ? NATIVES[name]() : null;

	return loaded[name];
};

/**
 * The real system's modules, the native ones loaded when a collector needs one.
 *
 * @returns {Modules} the modules.
 */
export function modules() {
	return {
		fs: { readfile, open, lsdir, glob, stat, lstat, realpath, popen, writefile, rename, unlink, chmod, mkstemp, stdin },
		ubus: { connect: (...args) => native('ubus')?.connect(...args) },
		uci: { cursor: () => cursor(null, NO_UCI_DELTAS) },
		native,
		time: () => time(),
		clock: () => clock(true),
		readable: (p) => stat(p) == null || !!access(p, 'r'),
		self_status: () => readfile('/proc/self/status'),
	};
};
