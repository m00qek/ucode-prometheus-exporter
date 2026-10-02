'use strict';

// The only module that touches the system. It takes each native function by
// name, so one that OpenWrt 25.12's ucode lacks fails this module's load rather
// than a scrape.
//
// modules(): the real fs, ubus, uci, rtnl, nl80211 and socket (these two when
// installed), time and a monotonic clock. Of fs, writefile, rename, unlink and
// chmod are the handler's, for its state (prometheus_exporter.state),
// mkstemp the runner's (prometheus_exporter.runner) and stdin the command
// line's: no collector gets them (FS_API).
// system_log(ident): a log(level, msg) to syslog, at the level's priority.
// session(mods): one scrape's capabilities over module-shaped objects, the real
// ones or utest's proxies: `for(meta)` hands a collector exactly its `needs`.

import { readfile, open, lsdir, glob, stat, realpath, popen, writefile, rename, unlink, chmod, mkstemp, stdin } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';
import { openlog, syslog, LOG_PID, LOG_DAEMON, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO } from 'log';
import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import { EXEC_TIMEOUT } from 'prometheus_exporter.config';

export const NEEDS = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket', 'exec', 'time', 'log', 'exporter' ];

// The functions of fs a collector may use. popen is exec's.
export const FS_API = [ 'readfile', 'open', 'lsdir', 'glob', 'stat', 'realpath' ];

// The status of a failed ubus call: what ucode's error() puts first, libubus's
// text for it ('Not found', 'Method not found'), before any ': ' and message.
// error() clears the error as it reads it, so the status is taken from its text.
export function ubus_status(message) {
	let i = index(message, ': ');

	return i < 0 ? message : substr(message, 0, i);
};

// The seconds a ubus call waits for its reply when nothing limits it: ucode's
// own default.
export const UBUS_TIMEOUT = 30;

// A ubus connection opened on first use, so a scrape that needs no ubus makes
// none. A null reply is not a failure by itself: only error() tells a method
// without data from a failed call, whose data is { status } (ubus_status).
//
// limit(t): the calls after it wait for no reply past `t` (monotonic seconds,
// clock_fn's), null for UBUS_TIMEOUT: a collector's ubus calls end by the time
// it is stopped, so a service that does not answer fails the call, saying so,
// rather than the collector. ucode's ubus takes one timeout per connection, in
// whole seconds, set when it connects: a call that needs a shorter one than
// its connection's connects again, which happens at most once a second, as a
// scrape's time runs down, and so does the first call under a new limit that
// allows a longer one; a call never waits less than a second.
export function ubus_channel(connect_fn, clock_fn) {
	let conn = null;
	let tried = false;
	let limit = null;
	let timeout = null;
	let connected_for = null;

	clock_fn ??= () => clock(true);

	function seconds_left() {
		if (limit == null)
			return UBUS_TIMEOUT;

		let t = clock_fn();
		let left = limit - (t[0] + t[1] / 1000000000.0);

		return min(UBUS_TIMEOUT, max(1, int(left + 0.999)));
	}

	function get() {
		let want = seconds_left();

		if (tried && conn && (want < timeout || (want > timeout && limit != connected_for))) {
			conn.disconnect();
			conn = null;
			tried = false;
		}

		if (!tried) {
			tried = true;
			timeout = want;
			connected_for = limit;
			conn = connect_fn(null, want);
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
					return Result.err(errors.UBUS_CALL_FAILED, `${object} ${method}: ${e}`, { status: ubus_status(e) });
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

		limit: function(t) {
			limit = t;
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

// The seconds a collector's commands get in all, in one scrape, when nobody
// says otherwise: the main section's exec_timeout by default (see config).
export const EXEC_SECONDS = EXEC_TIMEOUT;

// What a program's handle closes with when the watchdog killed it: the shell
// that ran it, killed by SIGKILL, which nothing else sends it.
export const EXEC_KILLED = -9;

// The shell script popen runs for a program, after a first line that sets $1 to
// the seconds it may take and the rest to its argv (exec_script). Only ash's
// builtins, as procd's jail has /bin/sh and the collectors' programs alone (no
// timeout, sleep or kill programs), and no process groups: ash turns job
// control off without a terminal. So:
//
// - the program runs in the background with its output on popen's pipe (fd 3),
//   while a subshell prints its pid and then its exit status into a pipe;
// - the other end reads the pid, then the status, for at most $1 seconds:
//   read -t, the shell's only clock, which counts whole seconds;
// - when no status came, it stops the program and every process under it,
//   found by their parent in /proc/<pid>/stat, until it finds no more (a
//   stopped process starts no other), then kills them all, and the shell popen
//   started with them: EXEC_KILLED. ssh under a script dies with the script.
//
// Otherwise the script exits with the program's status.
const WATCHDOG = join('\n', [
	't=$1; shift',
	'exec 3>&1 2>/dev/null',
	'{ "$@" >&3 3>&- & echo $!; wait $!; echo $?; } | {',
	'	read -r pid',
	'	if read -r -t "$t" st; then exit "$st"; fi',
	'	kill -STOP "$pid"',
	'	all=$pid new=$pid',
	'	while [ -n "$new" ]; do',
	'		parents=" $new " new=',
	'		for f in /proc/[0-9]*/stat; do',
	'			read -r s <"$f" || continue',
	'			set -- ${s##*) }',
	'			case $parents in *" $2 "*)',
	'				p=${f#/proc/} p=${p%/stat}',
	'				kill -STOP "$p" && new="$new $p" all="$all $p";;',
	'			esac',
	'		done',
	'	done',
	'	kill -KILL $all',
	'	kill -KILL $$',
	'}',
	'',
]);

// What popen runs for argv, given `seconds`: the first line sets the watchdog's
// arguments, each one single-quoted, so no shell interprets them.
export function exec_script(argv, seconds) {
	return `set -- ${seconds} ${join(' ', map(argv, shell_quote))}\n${WATCHDOG}`;
};

function milliseconds(t) {
	return t[0] * 1000 + t[1] / 1000000;
}

// run(argv): the standard output of one of the `allowed` programs, run without a
// shell's interpretation of its arguments. Its standard error is discarded. A
// failure's data is { status }: the exit status, null when it could not start.
//
// The channel's programs get `seconds` (EXEC_SECONDS by default) in all, from
// its first run; a channel is one collector's in one scrape. A program still
// running when they are spent is killed, with whatever it started, and fails
// with COMMAND_TIMEOUT; so does one asked to run after that, without running.
// Their data is { status: null, timed_out: true }. The shell counts whole
// seconds: a program gets what is left rounded up, so the commands of a channel
// take at most a second more than `seconds`. clock_fn: [ s, ns ], monotonic.
//
// `cutoff`, when given, is the time (monotonic seconds) the collector must be
// done by, for its scrape to answer in time: a program never runs past it. It
// gets the whole seconds left before it when they are fewer than its own, and
// does not run when not one is left; killed at the cutoff, or not run, it fails
// with SCRAPE_DEADLINE, its data { status: null, timed_out: true, deadline: true }.
export function exec_channel(popen_fn, allowed, seconds, clock_fn, cutoff) {
	seconds ??= EXEC_SECONDS;
	clock_fn ??= () => clock(true);

	let deadline = null;

	function timed_out(details) {
		return Result.err(errors.COMMAND_TIMEOUT, details, { status: null, timed_out: true });
	}

	function cut(details) {
		return Result.err(errors.SCRAPE_DEADLINE, details, { status: null, timed_out: true, deadline: true });
	}

	return {
		run: function(argv) {
			if (!(argv[0] in allowed))
				return Result.err(errors.COMMAND_NOT_ALLOWED, argv[0]);

			let now = milliseconds(clock_fn());
			deadline ??= now + seconds * 1000;

			if (now >= deadline)
				return timed_out(`${argv[0]}: not run, the collector's ${seconds} s for commands are spent`);

			let limit = (deadline - now + 999) / 1000;
			let at_cutoff = false;

			if (cutoff != null) {
				let left = int((cutoff * 1000 - now) / 1000);

				if (left < 1)
					return cut(`${argv[0]}: not run, less than a second is left before the scrape's deadline`);
				if (left < limit) {
					limit = left;
					at_cutoff = true;
				}
			}

			let p = popen_fn(exec_script(argv, limit), 'r');

			if (!p)
				return Result.err(errors.COMMAND_FAILED, `${argv[0]}: cannot start`, { status: null });

			let out = p.read('all');
			let status = p.close();

			if (status == EXEC_KILLED)
				return at_cutoff
					? cut(`${argv[0]}: still running at the scrape's deadline, after ${limit} s, killed`)
					: timed_out(`${argv[0]}: still running after ${limit} s, killed`);

			return status == 0
				? Result.ok(out)
				: Result.err(errors.COMMAND_FAILED, `${argv[0]}: exit status ${status}`, { status });
		},
	};
};

// The files of the serving process's /proc/<pid> exporter_channel reads.
export const PROCESS_FILES = [ 'stat', 'status', 'limits' ];

// The system's files exporter_channel reads: the boot time, and the
// auxiliary vector (the clock tick and the page size).
export const SYSTEM_FILES = [ '/proc/stat', '/proc/self/auxv' ];

// The exporter itself, read only, for its own collector: the process that
// serves the scrapes and the counters of its scrapes, and nothing else.
//   process(file)  /proc/<pid>/<file> of the serving process, for a file
//                  of PROCESS_FILES; null for any other
//   fds()          how many descriptors it has open, or null
//   system(file)   a file of SYSTEM_FILES, or null for any other
//   counters()     ledger.counters of its scrapes, this one's so far
//                  included, or null where there is no ledger
//   samples()      { collector: samples } of this scrape's collectors so far
// `view` is the scrape's, as data that crosses a process's pipe: { pid,
// counters, samples }; without it, the process is this one and there are no
// counters.
export function exporter_channel(fs, view) {
	let base = `/proc/${view?.pid ?? 'self'}`;

	return {
		process: (file) => (file in PROCESS_FILES) ? fs.readfile(`${base}/${file}`) : null,
		fds: function() {
			let entries = fs.lsdir(`${base}/fd`);

			return (entries == null) ? null : length(entries);
		},
		system: (file) => (file in SYSTEM_FILES) ? fs.readfile(file) : null,
		counters: () => view?.counters ?? null,
		samples: () => view?.samples ?? {},
	};
};

function uci_handle(cursor_fn, name) {
	let loaded = null;

	function cursor() {
		let c = cursor_fn();

		if (loaded == null)
			loaded = !!c.load(name);

		return c;
	}

	function sections(stype) {
		let c = cursor();
		let found = [];

		if (loaded)
			c.foreach(name, stype, (s) => { push(found, s); });

		return found;
	}

	return {
		loaded: function() {
			cursor();
			return loaded;
		},
		get: function(section, option) {
			let c = cursor();
			return loaded ? c.get(name, section, option) : null;
		},
		get_all: function(section) {
			let c = cursor();
			return loaded ? c.get_all(name, section) : null;
		},
		sections,
		foreach: function(stype, cb) {
			for (let s in sections(stype))
				cb(s);
		},
	};
}

// Read-only handles over uci configs: { <config>: handle } for each name in
// `configs`, and nothing else. A handle loads its config on first use and
// has loaded(), get(section, option), get_all(section), sections(type) and
// foreach(type, cb); no method writes. `cursor_fn` gives the scrape's shared
// cursor.
export function uci_handles(cursor_fn, configs) {
	let handles = {};

	for (let name in configs)
		handles[name] = uci_handle(cursor_fn, name);

	return handles;
};

// One scrape's capabilities: a ubus connection and a uci cursor shared by its
// collectors, and closed once it is over. mods.log, the exporter's log(level,
// msg), takes what collectors log, each line naming its collector, at warning:
// what a collector that succeeds still has to say is something it could not
// read.
export function session(mods) {
	let ubus = ubus_channel(mods.ubus.connect, mods.clock);
	let uci = null;
	let fs = {};

	for (let name in FS_API)
		fs[name] = mods.fs[name];

	function uci_cursor() {
		uci ??= mods.uci.cursor();
		return uci;
	}

	function capability(need, meta, settings, cutoff, view) {
		switch (need) {
		case 'fs':      return fs;
		case 'ubus':    return ubus;
		case 'uci':     return uci_handles(uci_cursor, meta.configs ?? []);
		case 'rtnl':    return mods.rtnl ? rtnl_channel(mods.rtnl) : null;
		case 'nl80211': return mods.nl80211 ? nl80211_channel(mods.nl80211) : null;
		case 'socket':  return mods.socket ? socket_channel(mods.socket) : null;
		case 'exec':    return exec_channel(mods.fs.popen, meta.commands ?? [], settings?.timeout ?? meta.timeout, mods.clock, cutoff);
		case 'time':    return { now: mods.time };
		case 'log':     return mods.log ? (msg) => mods.log('warning', `collector '${meta.name}': ${msg}`) : null;
		case 'exporter': return exporter_channel(mods.fs, view);
		}
	}

	return {
		uci: uci_cursor,

		// The deps object for a collector with this meta, or NEED_MISSING when
		// the system lacks one of its needs (nl80211 and socket are separate
		// packages). settings: what its config says (config.settings): exec's
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

// The levels the exporter logs at, as syslog's priorities. err: what stops it
// doing its job (an invalid configuration, a collector that does not load);
// warning: what it does without (a collector that fails, which the scrape
// answers without); notice and info: what it says of itself (how many
// collectors it serves, a directory it made).
export const LEVELS = { err: 'LOG_ERR', warning: 'LOG_WARNING', notice: 'LOG_NOTICE', info: 'LOG_INFO' };

// log(level, msg) over a syslog module (the `log` module's openlog, syslog and
// LOG_*): each message to syslog as the daemon `ident`, with its pid, at its
// level's priority. procd's log of a service's stderr has one priority for
// everything, err, which is why the exporter does not write there.
export function syslog_channel(mod, ident) {
	mod.openlog(ident, mod.LOG_PID, mod.LOG_DAEMON);

	return function(level, msg) {
		if (!(level in keys(LEVELS)))
			die(`unknown log level '${level}'`);

		mod.syslog(mod[LEVELS[level]], '%s', msg);
	};
};

export function system_log(ident) {
	return syslog_channel({ openlog, syslog, LOG_PID, LOG_DAEMON, LOG_ERR, LOG_WARNING, LOG_NOTICE, LOG_INFO }, ident);
};

// A delta directory that never exists: cursors read committed configuration
// only, not changes staged in uci and not yet committed.
const UCI_NO_DELTAS = '/var/run/prometheus-exporter/no-uci-deltas';

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
