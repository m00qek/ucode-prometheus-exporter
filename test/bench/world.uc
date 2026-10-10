'use strict';

// A world gen.uc wrote, as the modules prometheus.exporter.deps.session()
// takes: the real fs under the world's root, the real uci on its
// /etc/config, and stand-ins for ubus, rtnl and nl80211 answering from
// its JSON files. Programs (nft, ethtool) run for real, under deps' own watchdog,
// as `cat` of what the world says they print: a scrape pays for each process
// as on a router.

import * as fs from 'fs';
import { cursor } from 'uci';
import { exec_script } from 'prometheus.exporter.deps';

// What follows the command line in every script exec_script makes.
const TAIL = substr(exec_script([ '' ], 1), length("set -- 1 ''"));

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

// The constants are their own names: the stand-ins key replies by them.
const RTNL_CONST = { RTM_GETLINK: 'RTM_GETLINK', NLM_F_DUMP: 'NLM_F_DUMP' };
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
function rooted_fs(world, redirect) {
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
			let cmd = parse(script);
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
function netlink(replies, consts) {
	let last = null;

	return {
		const: consts,
		request: function(cmd, flags, attrs) {
			let key = attrs?.dev != null ? `${cmd}:${attrs.dev}` : cmd;
			let r = replies();

			last = (key in r) ? null : 'No such device';
			return r[key];
		},
		error: () => last,
	};
}

// The modules deps.session() takes, as deps.modules() gives the real ones.
// needs: the collectors' needs (meta.needs), whose sources are read now;
// with opts.lazy, when a collector first asks them, in the scrape, as a
// router's kernel and services answer then: what a scrape forks inherits no
// world it would not have on a router. opts.redirect: { path: file } read in
// place of the world's.
export function modules(world, needs, opts) {
	for (let need in (opts?.lazy ? [] : needs))
		if (need in [ 'ubus', 'nl80211', 'rtnl' ])
			source(world, need);

	return {
		fs: rooted_fs(world, opts?.redirect ?? {}),
		ubus: ubus(world),
		uci: { cursor: () => cursor(`${world.root}/etc/config`, '/nonexistent/uci-deltas') },
		rtnl: netlink(() => source(world, 'rtnl'), RTNL_CONST),
		nl80211: netlink(() => source(world, 'nl80211'), NL80211_CONST),
		socket: null,
		time: () => 1790850000,
		clock: () => clock(true),
	};
};
