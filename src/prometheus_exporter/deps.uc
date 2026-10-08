/**
 * The only module that touches the system, with the modules of its capabilities
 * (deps/<capability>.uc: ubus, netlink, socket, exec, exporter, uci, log). It
 * takes each native function by name, so one that OpenWrt 25.12's ucode lacks
 * fails this module's load rather than a scrape.
 *
 * It is the facade of deps/: the modules there are its own, and what others
 * take of them it exports, under the names below.
 *
 * modules(): the real fs, ubus, uci, rtnl, nl80211 and socket (these two when
 * installed), time and a monotonic clock. Of fs, writefile, rename, unlink and
 * chmod are the handler's, for its state (prometheus_exporter.state),
 * mkstemp the runner's (prometheus_exporter.runner) and stdin the command
 * line's: no collector gets them (FS_API).
 * system_log(ident): a log(level, msg) to syslog, at the level's priority.
 * session(mods): one scrape's capabilities over module-shaped objects, the real
 * ones or utest's proxies: `for(meta)` hands a collector exactly its `needs`.
 *
 * The capabilities' types are their modules': UbusCapability
 * (deps.ubus), NetlinkCapability (deps.netlink), SocketCapability
 * (deps.socket), ExecCapability (deps.exec), ExporterCapability
 * (deps.exporter), UciHandle (deps.uci) and Log (deps.log); fs's and time's,
 * and the Deps a collector gets, are this module's.
 *
 * @module prometheus_exporter_deps
 */

'use strict';

import { readfile, open, lsdir, glob, stat, realpath, popen, writefile, rename, unlink, chmod, mkstemp, stdin } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as ubus_module from 'prometheus_exporter.deps.ubus';
import * as netlink_module from 'prometheus_exporter.deps.netlink';
import * as socket_module from 'prometheus_exporter.deps.socket';
import * as exec_module from 'prometheus_exporter.deps.exec';
import * as exporter_module from 'prometheus_exporter.deps.exporter';
import * as uci_module from 'prometheus_exporter.deps.uci';
import * as log_module from 'prometheus_exporter.deps.log';

/**
 * deps.fs: the functions of the fs module a collector may use (FS_API), as
 * the fs module has them.
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
 * What collect() gets as `deps`: one capability per entry of meta.needs, by
 * name, and nothing else; a need the collector did not declare is absent.
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
 * One scrape's capabilities, as session() makes them: its uci cursor, the
 * deps of a collector (`for`, a Result of Deps, or NEED_MISSING), done(),
 * once that collector's run is over, and close(), once the scrape is.
 *
 * @typedef {{
 *   uci: () => UciCursor,
 *   for: (meta: Meta, settings: ?Settings, cutoff: ?float, view: ?ExporterView, limit: ?float) => Result<Deps>,
 *   done: () => void,
 *   close: () => void
 * }} Session
 */

/**
 * The modules a session is made over (modules()'s, or utest's proxies): fs
 * as the fs module has it, ubus's connect and uci's cursor, the netlink and
 * socket modules when installed, the time, a monotonic clock, and the log a
 * session adds.
 *
 * @typedef {{
 *   fs: module:fs,
 *   ubus: { connect: function(?string, ?int): ?UbusConnection },
 *   uci: { cursor: function(): UciCursor },
 *   rtnl: ?NetlinkModule,
 *   nl80211: ?NetlinkModule,
 *   socket: ?module:socket,
 *   time: () => int,
 *   clock: () => int[],
 *   log: ?Log
 * }} Modules
 */

// ubus: a scrape's channel, ucode's own timeout, the status of a failed call.
export const ubus_channel = ubus_module.ubus_channel;
export const UBUS_TIMEOUT = ubus_module.UBUS_TIMEOUT;
export const ubus_status = ubus_module.ubus_status;

// rtnl and nl80211: a module's requests as Results, and the modules by name.
export const rtnl_channel = netlink_module.rtnl_channel;
export const nl80211_channel = netlink_module.nl80211_channel;
export const load_rtnl = netlink_module.load_rtnl;
export const load_nl80211 = netlink_module.load_nl80211;

// socket: a Unix stream socket's request, and ucode-mod-socket by name.
export const socket_channel = socket_module.socket_channel;
export const load_socket = socket_module.load_socket;

// exec: a collector's programs under the watchdog, the script that runs
// one, how an argument is quoted, the seconds they get and how a killed one
// closes; and how a process is killed with every process under it.
export const exec_channel = exec_module.exec_channel;
export const kill_tree = exec_module.kill_tree;
export const exec_script = exec_module.exec_script;
export const shell_quote = exec_module.shell_quote;
export const EXEC_SECONDS = exec_module.EXEC_SECONDS;
export const EXEC_KILLED = exec_module.EXEC_KILLED;

// exporter: the exporter itself, read only, and the files it reads.
export const exporter_channel = exporter_module.exporter_channel;
export const PROCESS_FILES = exporter_module.PROCESS_FILES;
export const SYSTEM_FILES = exporter_module.SYSTEM_FILES;

// uci: read-only handles over the configs a collector declares.
export const uci_handles = uci_module.uci_handles;

// log: the exporter's log, syslog at each level's priority, and what a
// collector's run may log of it.
export const LEVELS = log_module.LEVELS;
export const LOG_LINES = log_module.LOG_LINES;
export const LOG_BYTES = log_module.LOG_BYTES;
export const syslog_channel = log_module.syslog_channel;
export const system_log = log_module.system_log;

/**
 * The capabilities a collector may need (meta.needs), each the name of what
 * it gets in deps.
 *
 * @type {string[]}
 */
export const NEEDS = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket', 'exec', 'time', 'log', 'exporter' ];

/**
 * The functions of fs a collector may use. popen is exec's.
 *
 * @type {string[]}
 */
export const FS_API = [ 'readfile', 'open', 'lsdir', 'glob', 'stat', 'realpath' ];

/**
 * One scrape's capabilities: a ubus connection and a uci cursor shared by its
 * collectors, and closed once it is over. mods.log, the exporter's log(level,
 * msg), takes what collectors log, each line naming its collector, at warning:
 * what a collector that succeeds still has to say is something it could not
 * read. A run's log takes LOG_LINES lines of LOG_BYTES at most; done(), once
 * the run is over, says how many more it left out.
 *
 * @param {Modules} mods the modules: modules()'s, or utest's proxies.
 * @returns {Session} the session.
 */
export function session(mods) {
	let ubus = ubus_channel(mods.ubus.connect, mods.clock);
	let uci = null;
	let fs = {};
	// The log of the run for() last made deps for: its collector's name, the
	// lines it logged, and those it left out.
	let run_log = null;

	for (let name in FS_API)
		fs[name] = mods.fs[name];

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

	function capability(need, meta, settings, cutoff, view) {
		switch (need) {
		// Copies: a collector that wrote over one of their functions would
		// change it for the collectors after it, as the others are made anew.
		case 'fs':      return { ...fs };
		case 'ubus':    return { ...ubus };
		case 'uci':     return uci_handles(uci_cursor, meta.configs ?? []);
		case 'rtnl':    return mods.rtnl ? rtnl_channel(mods.rtnl) : null;
		case 'nl80211': return mods.nl80211 ? nl80211_channel(mods.nl80211) : null;
		case 'socket':  return mods.socket ? socket_channel(mods.socket) : null;
		case 'exec':    return exec_channel(mods.fs.popen, meta.commands ?? [], settings?.timeout ?? meta.timeout, mods.clock, cutoff);
		case 'time':    return { now: mods.time };
		case 'log':     return mods.log ? log_of(meta.name) : null;
		case 'exporter': return exporter_channel(mods.fs, view);
		}
	}

	return {
		uci: uci_cursor,

		// The deps object for a collector with this meta, or NEED_MISSING when
		// the system lacks one of its needs (nl80211 and socket are separate
		// packages). Each call's is its own, each capability with it: what one
		// collector does to its deps no other sees. settings: what its config says (config.settings): exec's
		// programs get settings.timeout seconds, else meta.timeout's, and
		// never run past `cutoff` (exec_channel). `view`: the scrape's, for
		// exporter (exporter_channel). `limit`: when the collector is
		// stopped, which its ubus calls wait no longer than (ubus_channel).
		for: function(meta, settings, cutoff, view, limit) {
			let deps = {};

			ubus.limit(limit);

			for (let need in meta.needs) {
				let cap = capability(need, meta, settings, cutoff, view);

				if (cap == null)
					return Result.err(errors.NEED_MISSING, `${need} is not installed`);

				deps[need] = cap;
			}

			return Result.ok(deps);
		},

		// Once a run is over: how many lines its log left out, in one line.
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
 * The kernel's random bytes (RANDOM_DEVICE) through fs: random(n) gives n of
 * them, or null when it cannot read them; what auth.hash_password salts a
 * hash with, for the ubus object and the command line alike.
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

// A delta directory that never exists: cursors read committed configuration
// only, not changes staged in uci and not yet committed.
const UCI_NO_DELTAS = '/var/run/prometheus-exporter/no-uci-deltas';

/**
 * A uci cursor that writes and commits, over the staged changes uci keeps as
 * its own tools do: the ubus object's, for set_password alone, which commits
 * the hash's config (config.AUTH_CONFIG). What reads takes modules()'s.
 *
 * @returns {UciCursor} the cursor.
 */
export function writable_cursor() {
	return cursor();
};

/**
 * The real fs, ubus, uci, rtnl, nl80211 and socket (these two when
 * installed), time and a monotonic clock. Of fs, writefile, rename, unlink and
 * chmod are the handler's, for its state, mkstemp the runner's and stdin the
 * command line's: no collector gets them (FS_API). Cursors read committed
 * configuration only (UCI_NO_DELTAS).
 *
 * @returns {Modules} the modules.
 */
export function modules() {
	return {
		fs: { readfile, open, lsdir, glob, stat, realpath, popen, writefile, rename, unlink, chmod, mkstemp, stdin },
		ubus: { connect },
		uci: { cursor: () => cursor(null, UCI_NO_DELTAS) },
		rtnl: load_rtnl(),
		nl80211: load_nl80211(),
		socket: load_socket(),
		time: () => time(),
		clock: () => clock(true),
	};
};
