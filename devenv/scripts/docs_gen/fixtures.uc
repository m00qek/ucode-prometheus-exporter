'use strict';

// A fixture set of test/fixtures/ (caju-router, caju-ap, synthetic) as the
// modules prometheus.exporter.deps.session() takes, as deps.modules() gives the
// real ones: what the collectors read on a device, answered from its captures.
//
//   <set>/<path>                   a file at its path: /proc, /sys, /tmp, /var
//   <set>/links.json               where symlinks lead (realpath)
//   <set>/ubus/<obj>.<method>.json a ubus reply; <obj>.<method>.<name>.json for
//                                  a call with { name }
//   <set>/uci/<config>.json        a config's sections, as the uci mock's data
//   <set>/rtnl/<CMD>.json          a netlink dump; <CMD>.<dev>.json for one device
//   <set>/nl80211/<CMD>.<dev>.json the same for nl80211
//   <set>/commands/<line>.{txt,json}  what a program prints (command_file())
//   <set>/sockets/<name>.<request>.txt the reply of a Unix socket's server, or
//                                  of a TCP port's: <address>_<port>.<request>.txt
//
// What a set has no capture of is not there: a file is missing, a ubus object
// is 'Not found', a program fails, a socket refuses. rpcd's rc lists an init
// script, enabled, for each ubus object the set has a capture of (mwan3, dawn),
// and no other: a service the set has nothing of is not installed.
//
// One rule stands in for what the captures do not record: a link is backed by
// a device (/sys/class/net/<link>/device) when the set has `ethtool -S` of it,
// which was captured for those links only.

import * as fs from 'fs';
import { parse_batch } from 'prometheus.exporter.devkit.commands';

// The time deps.time.now() gives: any fixed second.
export const NOW = 1790850000;

function read_json(path) {
	let s = fs.readfile(path);

	return (s == null) ? null : json(s);
}

// The words of a command line, or of a capture's file name: each argument
// without its leading dashes, a path as its last part, split at '-' and '_'.
// `ethtool -S lan` and ethtool_S_lan.txt are [ ethtool, S, lan ].
export function words(args) {
	let out = [];

	for (let a in args) {
		let t = replace(a, /^-+/, '');

		if (index(t, '/') >= 0)
			t = replace(t, /^.*\//, '');
		push(out, ...filter(split(t, /[-_]/), (w) => w != ''));
	}

	return out;
};

// Whether `part` is `whole` with some words left out, in order.
function within(part, whole) {
	let i = 0;

	for (let w in whole)
		if (i < length(part) && part[i] == w)
			i++;

	return i == length(part);
}

// Of the capture file names `files`, the one of `argv`: the one with its very
// words, else the longest whose words it has in order, as a capture named
// before an option was added (chronyc_c_tracking.txt for `chronyc -u root -c
// tracking`); null for none.
export function command_file(files, argv) {
	let want = words(argv);
	let best = null, best_len = 0;

	for (let f in sort([ ...files ])) {
		let have = words([ replace(f, /\.(txt|json)$/, '') ]);

		if (have[0] != want[0] || !within(have, want))
			continue;
		if (length(have) == length(want))
			return f;
		if (length(have) > best_len) {
			best = f;
			best_len = length(have);
		}
	}

	return best;
};

// The words of a command line exec quoted, each single-quoted.
function line_argv(line) {
	let argv = [];

	for (let q in match(line, /'([^']|'\\'')*'/g) ?? [])
		push(argv, replace(substr(q[0], 1, length(q[0]) - 2), "'\\''", "'"));

	return argv;
}

// A script deps' exec runs: its argv, single-quoted after `set -- SECONDS`.
export function script_argv(script) {
	let first = split(script, '\n')[0];
	let m = match(first, /^set -- [0-9]+ (.*)$/);

	return m ? line_argv(m[1]) : null;
};

// The const of a netlink module, each name as its own value, as replies are
// keyed by name: the commands the set has captures of (RTM_GETLINK.json,
// NL80211_CMD_GET_STATION.phy0-ap0.json), and the flags. A command it has no
// capture of is null, and fails as one the kernel does not answer.
function names_of(dir) {
	let out = { NLM_F_DUMP: 'NLM_F_DUMP', NLM_F_REQUEST: 'NLM_F_REQUEST' };

	for (let f in fs.lsdir(dir) ?? []) {
		let m = match(f, /^([A-Z0-9_]+)[.]/);

		if (m)
			out[m[1]] = m[1];
	}

	return out;
}

function netlink(dir, consts) {
	let last = null;

	return {
		const: consts,
		request: function(cmd, flags, attrs) {
			let file = (attrs?.dev != null) ? `${dir}/${cmd}.${attrs.dev}.json` : `${dir}/${cmd}.json`;
			let text = fs.readfile(file);

			// A capture of an empty dump holds null: a reply, not a failure.
			last = (text == null) ? 'No such device' : null;
			return (text == null) ? null : json(text);
		},
		error: () => last,
	};
}

function uci_cursor(dir, overlay) {
	let configs = { ...(overlay ?? {}) };

	function data(config) {
		if (!(config in configs))
			configs[config] = read_json(`${dir}/${config}.json`);

		return configs[config];
	}

	function section(config, name) {
		let s = data(config)?.[name];

		return (type(s) == 'object') ? { '.name': name, '.anonymous': false, ...s } : null;
	}

	return {
		load: (config) => data(config) != null,
		get_all: section,
		get: function(config, name, option) {
			let s = section(config, name);

			return (option == null) ? s?.['.type'] : s?.[option];
		},
		foreach: function(config, stype, cb) {
			for (let name in sort(keys(data(config) ?? {}))) {
				let s = section(config, name);

				if (stype == null || s['.type'] == stype)
					cb(s);
			}
		},
	};
}

function ubus(dir) {
	let last = null;
	let objects = uniq(map(filter(fs.lsdir(dir) ?? [], (f) => match(f, /\.json$/)),
		(f) => replace(f, /\.[^.]+\.json$/, '')));

	return {
		connect: () => ({
			call: function(object, method, args) {
				let reply = (args?.name != null) ? read_json(`${dir}/${object}.${method}.${args.name}.json`) : null;

				reply ??= read_json(`${dir}/${object}.${method}.json`);
				if (reply == null && object == 'rc' && method == 'list')
					reply = (args?.name in objects) ? { [args.name]: { start: 19, enabled: true } } : {};

				last = (reply == null) ? 'Not found' : null;
				return reply;
			},
			list: () => sort(objects),
			error: function() {
				let e = last;

				last = null;
				return e;
			},
			disconnect: () => true,
		}),
	};
}

// A Unix socket whose server answers `<name>.<request>.txt` once, where <name>
// is the socket's file name without its extension and <request> the last word
// of what the client sent: unbound.ctl and `UBCT1 stats_noreset`. A TCP port
// of the device, any address of it, is the same, its <name> `<address>_<port>`
// and its <request> the second word of the first line, an HTTP request's
// path, without its first '/' and the others as '_': 127.0.0.1_8080 and
// `GET /control/stats HTTP/1.0`, control_stats.
function socket(dir) {
	let last = null;

	function file_of(st) {
		if (st.address != null) {
			let words = split(split(st.sent, '\n')[0], /\s+/);

			return `${st.address}_${st.port}.${replace(replace(words[1] ?? '', /^\//, ''), /\//g, '_')}.txt`;
		}

		let name = replace(replace(st.path ?? '', /^.*\//, ''), /\.[^.]*$/, '');
		let words = split(trim(st.sent), /\s+/);

		return `${name}.${words[length(words) - 1]}.txt`;
	}

	return {
		AF_UNIX: 1, AF_INET: 2, AF_INET6: 10, SOCK_STREAM: 1, SOL_SOCKET: 1, SO_RCVTIMEO: 20, SO_SNDTIMEO: 21, MSG_NOSIGNAL: 0x4000,
		create: function() {
			let st = { path: null, address: null, port: null, sent: '', reply: null };

			return {
				setopt: () => true,
				bind: () => true,
				connect: function(addr) {
					st.path = addr?.path;
					st.address = addr?.address;
					st.port = addr?.port;
					return true;
				},
				send: function(data) {
					st.sent += data;
					return length(data);
				},
				recv: function() {
					if (st.reply == null) {
						st.reply = fs.readfile(`${dir}/${file_of(st)}`);
						if (st.reply == null) {
							last = 'connect(): Connection refused';
							return null;
						}

						return st.reply;
					}

					return '';
				},
				close: () => true,
			};
		},
		error: (numeric) => numeric ? 111 : last,
	};
}

// The modules of fixture set `dir`, the directory of the set. `overlay` holds
// configs, as the uci mock's data, in place of the set's: the exporter's own.
export function modules(dir, overlay) {
	let links = read_json(`${dir}/links.json`) ?? {};
	let at = (p) => dir + p;
	let strip = (p) => (p != null && substr(p, 0, length(dir)) == dir) ? substr(p, length(dir)) : p;

	function backed(p) {
		let m = match(p, /^\/sys\/class\/net\/([^\/]+)\/device$/);

		return m && fs.stat(`${dir}/commands/ethtool_S_${m[1]}.txt`) != null;
	}

	function capture(argv) {
		let f = command_file(fs.lsdir(`${dir}/commands`) ?? [], argv);

		return (f != null) ? fs.readfile(`${dir}/commands/${f}`) : null;
	}

	// A batch of run_all(): each program's capture and 0, or nothing and 1.
	function popen(script, mode) {
		let batch = parse_batch(script);

		if (batch) {
			let text = '';

			for (let line in batch.lines) {
				let out = capture(line_argv(line));

				text += `${out ?? ''}\n${batch.mark} ${(out != null) ? 0 : 1}\n`;
			}

			return { read: () => text, close: () => 0 };
		}

		let argv = script_argv(script);

		if (argv == null)
			return null;

		let out = capture(argv);

		return (out != null) ? { read: () => out, close: () => 0 } : { read: () => '', close: () => 1 };
	}

	return {
		fs: {
			readfile: (p, n) => fs.readfile(at(p), n),
			open: (p, mode) => fs.open(at(p), mode),
			lsdir: (p) => fs.lsdir(at(p)),
			glob: (...pats) => map(fs.glob(...map(pats, at)) ?? [], strip),
			stat: (p) => backed(p) ? { type: 'directory' } : fs.stat(at(p)),
			realpath: (p) => links[p] ?? strip(fs.realpath(at(p))),
			popen,
		},
		ubus: ubus(`${dir}/ubus`),
		uci: { cursor: () => uci_cursor(`${dir}/uci`, overlay) },
		rtnl: netlink(`${dir}/rtnl`, names_of(`${dir}/rtnl`)),
		nl80211: netlink(`${dir}/nl80211`, names_of(`${dir}/nl80211`)),
		socket: socket(`${dir}/sockets`),
		time: () => NOW,
		clock: () => [ 0, 0 ],
	};
};
