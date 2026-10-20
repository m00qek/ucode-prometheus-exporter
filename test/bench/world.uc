'use strict';

// A world gen.uc wrote, as the modules prometheus.exporter.deps.session()
// takes: the real fs under the world's root, the real uci on its
// /etc/config, and stand-ins for ubus, rtnl and nl80211 answering from
// its JSON files, and for socket answering a TCP port's requests from its
// files. Programs (nft, ethtool) run for real, under deps' own watchdog,
// as `cat` of what the world says they print: a scrape pays for each process
// as on a router. opts.tally counts what the modules were asked: netlink
// requests, the watchdog's runs and the programs in them, connections.

import * as fs from 'fs';
import { cursor } from 'uci';
import * as deps from 'prometheus.exporter.deps';

const exec_script = deps.exec_script;

// What follows the command line in every script exec_script makes.
const TAIL = substr(exec_script([ '' ], 1), length("set -- 1 ''"));

// The shell function of a script of run_all(), which another revision's exec
// may not have.
const BATCH = deps.BATCH ?? '_prometheus_exporter_batch';
const BATCH_HEAD = `${BATCH}() {\n`;
const BATCH_LINE = "\nprintf '\\n%s %d\\n' '";

// { seconds, line } of a script deps' exec runs, or null for any other
// command: the devkit's commands.parse, here so that the bench runs on the
// src/ of another revision (BENCH_REV), which may have no devkit.
function parse(script) {
	let head = match(script, /^set -- ([0-9]+) /);

	if (!head || length(script) < length(head[0]) + length(TAIL) || substr(script, -length(TAIL)) != TAIL)
		return null;

	return {
		seconds: +head[1],
		line: substr(script, length(head[0]), length(script) - length(head[0]) - length(TAIL)),
	};
}

// { seconds, mark, lines } of a script of run_all(), or null: the devkit's
// commands.parse_batch, here for the same reason.
function parse_batch(script) {
	let end = index(script, '\n}\nset -- ');

	if (substr(script, 0, length(BATCH_HEAD)) != BATCH_HEAD || end < 0)
		return null;

	let run = parse(substr(script, end + 3));
	let body = substr(script, length(BATCH_HEAD), end + 1 - length(BATCH_HEAD));
	let at = index(body, BATCH_LINE);

	if (run?.line != `'${BATCH}'` || at < 0)
		return null;

	let mark = substr(body, at + length(BATCH_LINE));
	mark = substr(mark, 0, index(mark, "'"));

	let lines = split(body, `${BATCH_LINE}${mark}' "$?"\n`);

	pop(lines);
	return { seconds: run.seconds, mark, lines };
}

// The constants are their own names: the stand-ins key replies by them.
const RTNL_CONST = { RTM_GETLINK: 'RTM_GETLINK', RTM_GETROUTE: 'RTM_GETROUTE', NLM_F_DUMP: 'NLM_F_DUMP', RTN_UNICAST: 1, RTN_LOCAL: 2 };
const NL80211_CONST = {
	NL80211_CMD_GET_INTERFACE: 'NL80211_CMD_GET_INTERFACE',
	NL80211_CMD_GET_STATION: 'NL80211_CMD_GET_STATION',
	NL80211_CMD_GET_SURVEY: 'NL80211_CMD_GET_SURVEY',
	NLM_F_DUMP: 'NLM_F_DUMP',
};

export function load(dir) {
	let w = json(fs.readfile(`${dir}/world.json`) ?? die(`no world in ${dir}; run gen.uc`));

	w.dir = dir;
	w.root = `${dir}/root`;
	return w;
};

// What the exporter collector reads of the process that serves the scrapes,
// which no world holds: a real process's, the bench's own (self), or the
// one an instance's id names.
const PROCESS = /^\/proc\/(self|[0-9]+)\/(stat|status|limits|fd|auxv)$/;

// fs over the world's root. `redirect` maps a path to another file: the
// conntrack table of a scaling case.
function rooted_fs(world, redirect, tally) {
	let root = world.root;
	let at = (p) => redirect[p] ?? (match(p, PROCESS) ? p : (root + p));
	let strip = (p) => (p != null && substr(p, 0, length(root)) == root) ? substr(p, length(root)) : p;

	return {
		readfile: (p, n) => fs.readfile(at(p), n),
		open: (p, mode) => fs.open(at(p), mode),
		lsdir: (p) => fs.lsdir(at(p)),
		glob: (...pats) => map(fs.glob(...map(pats, at)) ?? [], strip),
		stat: (p) => fs.stat(at(p)),
		realpath: (p) => strip(fs.realpath(at(p))),
		popen: function(script, mode) {
			let batch = parse_batch(script);
			let cmd = batch ? null : parse(script);

			if (batch || cmd) {
				tally.runs++;
				tally.programs += batch ? length(batch.lines) : 1;
			}

			// The programs of a batch, each `cat` of its output or `false`, in
			// one watchdog as exec runs them.
			if (batch)
				return fs.popen(deps.batch_script(map(batch.lines, (l) => (world.commands[l] != null) ? [ 'cat', `${world.dir}/${world.commands[l]}` ] : [ 'false' ]),
					batch.seconds, batch.mark), mode);

			let out = cmd ? world.commands[cmd.line] : null;

			// A program the world has no output for fails, as ethtool -S does
			// for a device without driver statistics (lo, a bridge).
			if (!cmd)
				return null;

			return fs.popen(exec_script(out != null ? [ 'cat', `${world.dir}/${out}` ] : [ 'false' ], cmd.seconds), mode);
		},
	};
}

// What a source answers, read once: a case reads only the sources its
// collectors need, so its memory is theirs and not the whole world's.
function source(world, name) {
	world[name] ??= json(fs.readfile(`${world.dir}/${name}.json`));
	return world[name];
}

function ubus(world) {
	let last = null;

	return {
		connect: () => ({
			call: function(object, method, args) {
				let reply = source(world, 'ubus')[`${object}:${method}`];

				last = reply == null ? 'Not found' : null;
				return reply;
			},
			list: () => uniq(map(keys(source(world, 'ubus')), (k) => split(k, ':')[0])),
			error: () => last,
			disconnect: () => true,
		}),
	};
}

// replies(): the source's replies, read when first asked.
function netlink(replies, consts, count) {
	let last = null;

	return {
		const: consts,
		request: function(cmd, flags, attrs) {
			let key = attrs?.dev != null ? `${cmd}:${attrs.dev}` : cmd;

			count();
			let r = replies();

			last = (key in r) ? null : 'No such device';
			return r[key];
		},
		error: () => last,
	};
}

// A TCP port's server: the reply to a request is the world's file for its
// address, port and path (world.sockets['<address>:<port> <path>']), sent
// whole at the first read; one it has none for is refused.
function socket(world, tally) {
	let last = null;
	let at = (st) => world.sockets?.[`${st.to} ${split(split(st.sent, '\r\n')[0], ' ')[1]}`];

	return {
		AF_UNIX: 1, AF_INET: 2, AF_INET6: 10, SOCK_STREAM: 1, SOL_SOCKET: 1, SO_RCVTIMEO: 20, SO_SNDTIMEO: 21, MSG_NOSIGNAL: 0x4000,
		create: function() {
			let st = { to: null, sent: '', reply: null };

			return {
				setopt: () => true,
				bind: () => true,
				connect: function(addr) {
					tally.connections++;
					st.to = `${addr?.address}:${addr?.port}`;
					return true;
				},
				send: function(data) {
					st.sent += data;
					return length(data);
				},
				recv: function() {
					if (st.reply != null)
						return '';

					let file = at(st);

					st.reply = (file != null) ? fs.readfile(`${world.dir}/${file}`) : null;
					if (st.reply == null)
						last = 'connect(): Connection refused';
					return st.reply;
				},
				close: () => true,
			};
		},
		error: (numeric) => numeric ? 111 : last,
	};
}

// The modules deps.session() takes, as deps.modules() gives the real ones.
// needs: the collectors' needs (meta.needs), whose sources are read now;
// with opts.lazy, when a collector first asks them, in the scrape, as a
// router's kernel and services answer then: what a scrape forks inherits no
// world it would not have on a router. opts.redirect: { path: file } read in
// place of the world's.
export function modules(world, needs, opts) {
	let tally = opts?.tally ?? {};

	for (let k in [ 'rtnl', 'nl80211', 'runs', 'programs', 'connections' ])
		tally[k] = 0;

	for (let need in (opts?.lazy ? [] : needs))
		if (need in [ 'ubus', 'nl80211', 'rtnl' ])
			source(world, need);

	return {
		fs: rooted_fs(world, opts?.redirect ?? {}, tally),
		ubus: ubus(world),
		uci: { cursor: () => cursor(`${world.root}/etc/config`, '/nonexistent/uci-deltas') },
		rtnl: netlink(() => source(world, 'rtnl'), RTNL_CONST, () => tally.rtnl++),
		nl80211: netlink(() => source(world, 'nl80211'), NL80211_CONST, () => tally.nl80211++),
		socket: socket(world, tally),
		time: () => 1790850000,
		clock: () => clock(true),
	};
};
