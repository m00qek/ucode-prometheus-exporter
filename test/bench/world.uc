'use strict';

// A world gen.uc wrote, as the modules prometheus_exporter.deps.session()
// takes: the real fs under the world's root, the real uci on its
// /etc/config, and stand-ins for ubus, rtnl and nl80211 answering from
// world.json. Programs (nft, ethtool) run for real, under deps' own watchdog,
// as `cat` of what the world says they print: a scrape pays for each process
// as on a router.

import * as fs from 'fs';
import { cursor } from 'uci';
import { exec_script } from 'prometheus_exporter.deps';
import { parse } from 'lib.commands';

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

// fs over the world's root. `redirect` maps a path to another file: the
// conntrack table of a scaling case.
function rooted_fs(world, redirect) {
	let root = world.root;
	let at = (p) => redirect[p] ?? (root + p);
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

function ubus(world) {
	let last = null;

	return {
		connect: () => ({
			call: function(object, method, args) {
				let reply = world.ubus[`${object}:${method}`];

				last = reply == null ? 'Not found' : null;
				return reply;
			},
			list: () => uniq(map(keys(world.ubus), (k) => split(k, ':')[0])),
			error: () => last,
			disconnect: () => true,
		}),
	};
}

function netlink(replies, consts) {
	let last = null;

	return {
		const: consts,
		request: function(cmd, flags, attrs) {
			let key = attrs?.dev != null ? `${cmd}:${attrs.dev}` : cmd;

			last = (key in replies) ? null : 'No such device';
			return replies[key];
		},
		error: () => last,
	};
}

// The modules deps.session() takes, as deps.modules() gives the real ones.
// opts.redirect: { path: file } read in place of the world's.
export function modules(world, opts) {
	return {
		fs: rooted_fs(world, opts?.redirect ?? {}),
		ubus: ubus(world),
		uci: { cursor: () => cursor(`${world.root}/etc/config`, '/nonexistent/uci-deltas') },
		rtnl: netlink(world.rtnl, RTNL_CONST),
		nl80211: netlink(world.nl80211, NL80211_CONST),
		socket: null,
		time: () => 1790850000,
		clock: () => clock(true),
	};
};
