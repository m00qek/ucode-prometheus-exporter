'use strict';

// with_mods(cfg, cb): inject utest's mocks (strict unless cfg says otherwise) and
// call cb with module-shaped objects for deps.session(), as deps.modules() gives
// the real ones.
//
// with_collector(mod, cfg, cb): run one collector module the way a scrape does,
// with only its needs, and call cb with { result, text, lines, logs, levels,
// families }; `logs` has what the scrape and the collector itself logged, and
// `levels` the level of each. It asserts nothing of the result: a test does.
//
// It holds the collector to its contract, as the exporter would (the tests
// fail, with assert.fail(), before cb runs):
// - its meta must be valid, and its output parse as exposition text;
// - it touches only what its meta declares, in the filesystem the service's
//   jail gives it: the jail's mounts for its meta (jail_of's) and every
//   jail's (prometheus_exporter.jail's COMMON). A read, a listing, a glob, a
//   stat, a realpath or an open of a path outside them answers as it does in
//   the jail (null, or what the jail makes of a directory above a mount),
//   whatever the fs mock holds; so does a connection to a socket outside them
//   ('No such file or directory'). An open for writing fails, as the jail's
//   mounts are read-only. And a program not in meta.commands is refused
//   (COMMAND_NOT_ALLOWED), as it always is, and so is a ubus call not in
//   meta.ubus (UBUS_NOT_ALLOWED), as the service's ubus ACL would.
// Each such access is recorded, and the test fails after the run, saying what
// the collector touched and how to declare it. Not from inside the run: the
// collector's error boundary would take a failure there for a crash, and a
// collector that falls back on a default (readfile(p) ?? '') would pass.
//
// outcome(r): what a test checks of with_collector's run that has nothing to
// observe, or fails: { ok, none, error, lines, logs }.
//
// jail_of(mod, cfg): what prometheus_exporter.jail gives the collector module in the
// exporter's jail, its config as with_collector's; cfg.files are the regular
// files commands are found among, cfg.absent the paths that are not there (any
// other path is, as a directory).
//
// cfg: { fs, ubus, uci, rtnl, nl80211, socket }: each mock's config ({ data, commands, errors, ... });
//      options: the collector's `config collector` section;
//      main: the main section; no_nl80211, no_rtnl, no_socket: as if that module were missing;
//      time: what deps.time.now() returns;
//      self_status: the text of /proc/self/status the session checks
//      meta.capabilities against; unreadable: the paths the process may not
//      read (a config, a proc file); without them nothing is checked;
//      outside_jail: paths a collector looks for knowing the service's jail never has
//      them, for what it does where it runs outside the jail (chrony's command socket):
//      the mocks answer them as they hold them, and the contract check lets them be.
//      Each is a choice its collector documents, and nothing else.

import { mock, assert } from 'utest';
import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as scrape from 'prometheus_exporter.scrape';
import * as exposition from 'prometheus_exporter.exposition';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import * as errors from 'prometheus_exporter.errors';
import * as Result from 'prometheus_exporter.result';

const MOCKED = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket' ];

function uci_config(cfg, id) {
	let data = { ...(cfg.uci?.data ?? {}) };
	let pkg = { ...(data[config.NAME] ?? {}) };

	if (cfg.main)
		pkg.main = { '.type': config.NAME, ...cfg.main };
	if (cfg.options && id)
		pkg[id] = { '.type': 'collector', ...cfg.options };

	data[config.NAME] = pkg;
	return { ...(cfg.uci ?? {}), data };
}

function inject_each(cfgs, names, proxies, cb) {
	if (!length(names))
		return cb(proxies);

	let name = names[0];
	mock.inject(name, { strict: true, data: {}, ...cfgs[name] }, function(proxy) {
		proxies[name] = proxy;
		inject_each(cfgs, slice(names, 1), proxies, cb);
	});
}

export function with_mods(cfg, cb, id) {
	let cfgs = {};

	for (let name in MOCKED)
		cfgs[name] = cfg[name] ?? {};
	cfgs.uci = uci_config(cfg, id);

	inject_each(cfgs, MOCKED, {}, (p) => cb({
		fs: p.fs,
		ubus: p.ubus,
		uci: p.uci,
		rtnl: cfg.no_rtnl ? null : p.rtnl,
		nl80211: cfg.no_nl80211 ? null : p.nl80211,
		socket: cfg.no_socket ? null : p.socket,
		time: () => cfg.time ?? 0,
		readable: cfg.unreadable ? (path) => !(path in cfg.unreadable) : null,
		self_status: (cfg.self_status != null) ? () => cfg.self_status : null,
	}));
};

// A module's collector, or a failed test: a meta the loader refuses is the
// collector's to fix, not the test's.
function valid_collector(mod) {
	let id = loader.id_of(mod?.meta?.name ?? '');
	let valid = loader.validate(id, mod);

	if (!valid.ok)
		assert.fail(`collector '${mod?.meta?.name}' has a meta the loader refuses: ${Result.describe(valid)}.\n` +
			'The exporter leaves it out, logged at err: fix its meta.');

	return valid.data;
}

// ---- the filesystem of the jail ------------------------------------------------

// A path as the kernel resolves it, without links: '.', '..' and '//' gone.
// Null for a path that is not absolute.
function normal(p) {
	if (type(p) != 'string' || substr(p, 0, 1) != '/')
		return null;

	let parts = [];

	for (let part in split(p, '/')) {
		if (part == '' || part == '.')
			continue;
		if (part == '..')
			pop(parts);
		else
			push(parts, part);
	}

	return '/' + join('/', parts);
}

// Whether `mount` holds path `p`: it, or what is under it; a mount that ends
// in '*', every path that starts with the rest.
function holds(mount, p) {
	if (substr(mount, -1) == '*')
		return substr(p, 0, length(mount) - 1) == substr(mount, 0, -1);

	return p == mount || substr(p, 0, length(mount) + 1) == mount + '/';
}

function inside(mounts, p) {
	for (let m in mounts)
		if (holds(m, p))
			return true;

	return false;
}

// What the jail makes of directory `p` above some mounts: the names in it,
// the first part of each mount under it, sorted; null when no mount is under it.
function above(mounts, p) {
	let prefix = (p == '/') ? '/' : p + '/';
	let names = {};

	for (let m in mounts)
		if (substr(m, 0, length(prefix)) == prefix && substr(m, -1) != '*')
			names[split(substr(m, length(prefix)), '/')[0]] = true;

	return length(names) ? sort(keys(names)) : null;
}

// The directory a glob pattern starts in: its path up to its first part with
// a pattern character in it.
function glob_base(pattern) {
	let parts = [];

	for (let part in split(pattern, '/')) {
		if (match(part, /[*?[]/))
			break;
		push(parts, part);
	}

	return normal(join('/', parts) || '/');
}

// fs, as the jail gives it to a collector with these mounts: what is outside
// them answers as in the jail, and is recorded with touched(access).
function jailed_fs(fs, mounts, touched) {
	function outside(op, path, got, extra) {
		touched({ kind: 'fs', op, path, got, ...(extra ?? {}) });
		return got;
	}

	return {
		...fs,

		readfile: function(path, ...rest) {
			let p = normal(path);

			return (p != null && inside(mounts, p)) ? fs.readfile(path, ...rest) : outside('readfile', path, null);
		},

		open: function(path, mode, ...rest) {
			let p = normal(path);

			if (mode != null && !match(mode, /^r[be]*$/))
				return outside('write', path, null, { mode });

			return (p != null && inside(mounts, p)) ? fs.open(path, mode, ...rest) : outside('open', path, null);
		},

		lsdir: function(path, ...rest) {
			let p = normal(path);

			return (p != null && inside(mounts, p)) ? fs.lsdir(path, ...rest) : outside('lsdir', path, p != null ? above(mounts, p) : null);
		},

		stat: function(path) {
			let p = normal(path);

			if (p != null && inside(mounts, p))
				return fs.stat(path);

			return outside('stat', path, (p != null && above(mounts, p)) ? { type: 'directory', size: 0, mtime: 0 } : null);
		},

		realpath: function(path) {
			let p = normal(path);

			if (p != null && inside(mounts, p))
				return fs.realpath(path);

			return outside('realpath', path, (p != null && above(mounts, p)) ? p : null);
		},

		glob: function(pattern, ...rest) {
			let base = glob_base(pattern);

			if (base != null && inside(mounts, base))
				return fs.glob(pattern, ...rest);

			// The jail has what is mounted under the base, and nothing else.
			let all = fs.glob(pattern, ...rest) ?? [];
			let kept = filter(all, (f) => inside(mounts, normal(f) ?? ''));

			return outside('glob', pattern, kept);
		},
	};
}

// ucode-mod-socket, as the jail gives it: a Unix socket outside the mounts is
// not there.
function jailed_socket(mod, mounts, touched) {
	let refused = null;

	return {
		...mod,

		create: function(...args) {
			let sock = mod.create(...args);

			refused = null;
			if (sock == null)
				return sock;

			return {
				...sock,
				connect: function(addr, ...rest) {
					let path = (type(addr) == 'string') ? addr : addr?.path;
					let p = normal(path);

					if (p != null && inside(mounts, p))
						return sock.connect(addr, ...rest);

					touched({ kind: 'socket', path });
					refused = 'connect(): No such file or directory';
					return null;
				},
			};
		},

		error: function(numeric) {
			if (refused != null)
				return numeric ? 2 : refused;

			return mod.error(numeric);
		},
	};
}

// The session for a collector's run, whose exec and ubus capabilities record
// a program or a ubus call they refuse as not declared.
function watched_session(session, touched) {
	return {
		...session,

		for: function(...args) {
			let res = session.for(...args);
			let exec = res.ok ? res.data.exec : null;
			let ubus = res.ok ? res.data.ubus : null;

			if (exec == null && ubus == null)
				return res;

			let d = { ...res.data };

			if (exec)
				d.exec = {
					...exec,
					run: function(argv, ...rest) {
						let r = exec.run(argv, ...rest);

						if (!r.ok && r.error == errors.COMMAND_NOT_ALLOWED)
							touched({ kind: 'exec', program: argv?.[0] });

						return r;
					},
				};

			if (ubus)
				d.ubus = {
					...ubus,
					call: function(object, method, ...rest) {
						let r = ubus.call(object, method, ...rest);

						if (!r.ok && r.error == errors.UBUS_NOT_ALLOWED)
							touched({ kind: 'ubus', object, method });

						return r;
					},
				};

			return Result.ok(d);
		},
	};
}

// ---- what the test says of an access ------------------------------------------

// By fs function: what the collector did, what it would stop doing, and what
// the jail answers for a path that is not there.
const VERBS = {
	readfile: [ 'read', 'reading', 'that path does not exist: the read returns null' ],
	open: [ 'opened', 'opening', 'that path does not exist: the open returns null' ],
	lsdir: [ 'listed', 'listing', 'that directory does not exist: lsdir returns null' ],
	stat: [ 'looked up (stat)', 'looking it up', 'that path does not exist: stat returns null' ],
	realpath: [ 'resolved (realpath)', 'resolving it', 'that path does not exist: realpath returns null' ],
	glob: [ 'globbed', 'globbing', 'nothing is there: glob matches nothing' ],
};

function dirname(p) {
	let m = match(p ?? '', /^(.*)\/[^\/]*$/);

	return (m && m[1] != '') ? m[1] : '/';
}

// Where to declare `path`: the path, or its directory, when that may be one;
// `doing`, what the collector would stop doing instead.
function declare(path, doing) {
	let p = normal(path);
	let stop = (index(doing, ' it') > 0) ? `stop ${doing}` : `stop ${doing} it`;

	if (p == null)
		return `Use an absolute path, declared in meta.paths, or ${stop}.`;
	if (jail.path_problem(p) != null)
		return `It cannot be declared (${jail.path_problem(p)}): ${stop}.`;

	let dir = dirname(p);

	return (jail.path_problem(dir) == null)
		? `Declare it in meta.paths (or its directory: '${dir}'), or ${stop}.`
		: `Declare it in meta.paths, or ${stop}.`;
}

function json_of(v) {
	return sprintf('%J', v);
}

// The message of one access, for collector `name` whose declared paths are
// `declared`, programs `commands` and ubus calls `calls`.
function message(name, a, declared, commands, calls) {
	let paths = `Declared: ${join(', ', declared)}`;

	if (a.kind == 'ubus')
		return join('\n', [
			`collector '${name}' called ubus ${a.object} ${a.method}, which its meta.ubus does not list.`,
			'The exporter refuses it, in the jail or not: call() returns UBUS_NOT_ALLOWED without calling it, as it did here; ' +
			"the service's ubus ACL, made of what its collectors declare, would refuse it too. A test that expects the collector to fail may pass by accident.",
			`Declare it in meta.ubus, as { '${a.object}': [ '${a.method}' ] }, with 'ubus' in meta.needs, or stop calling it.`,
			`Declared calls: ${length(calls) ? join(', ', map(keys(calls), (o) => `${o} ${join('|', calls[o])}`)) : 'none'}`,
		]);

	if (a.kind == 'exec')
		return join('\n', [
			`collector '${name}' ran '${a.program}', which its meta.commands does not list.`,
			'The exporter refuses it, in the jail or not: run() returns COMMAND_NOT_ALLOWED without running it, as it did here. ' +
			'A test that expects the collector to fail may pass by accident.',
			"List it in meta.commands, with 'exec' in meta.needs, or stop running it.",
			`Declared commands: ${length(commands) ? join(', ', commands) : 'none'}`,
		]);

	if (a.kind == 'socket') {
		let p = normal(a.path);
		let dir = dirname(p);
		let how = (p == null) ? 'Use an absolute path, its directory declared in meta.paths, or stop connecting to it.'
			: (jail.path_problem(dir) == null)
				? `Declare its directory in meta.paths ('${dir}'): the jail cannot mount a socket itself. Or stop connecting to it.`
				: `Its directory cannot be declared (${jail.path_problem(dir)}): stop connecting to it.`;

		return join('\n', [
			`collector '${name}' connected to the socket ${a.path}, which its meta does not declare.`,
			"In the service's jail that socket is not there: connect fails with 'No such file or directory', as it did here.",
			how,
			paths,
		]);
	}

	if (a.op == 'write')
		return join('\n', [
			`collector '${name}' opened ${a.path} to write ('${a.mode}').`,
			"In the service's jail what a collector may read is mounted read-only: the open fails and returns null, as it did here.",
			'A collector writes samples, and nothing else: stop writing it.',
		]);

	let v = VERBS[a.op];
	let jailed = v[2];

	if (a.op == 'lsdir' && a.got != null)
		jailed = `it holds only what is mounted under it: lsdir returns ${json_of(a.got)}`;
	else if ((a.op == 'stat' || a.op == 'realpath') && a.got != null)
		jailed = `it is a directory the jail makes for what is mounted under it: ${a.op} finds it`;
	else if (a.op == 'glob' && length(a.got))
		jailed = `glob matches only what is mounted: ${json_of(a.got)}`;

	return join('\n', [
		`collector '${name}' ${v[0]} ${a.path}, which its meta does not declare.`,
		`In the service's jail ${jailed}, as it did here.`,
		declare((a.op == 'glob') ? (glob_base(a.path) ?? a.path) : a.path, v[1]),
		paths,
	]);
}

// The message of everything a run touched outside its contract, each once, or
// null.
function contract_failure(name, touched, declared, commands, calls) {
	let seen = {};
	let out = [];

	for (let a in touched) {
		let key = json_of(a);

		if (seen[key])
			continue;
		seen[key] = true;
		push(out, message(name, a, declared, commands, calls));
	}

	return length(out) ? join('\n\n', out) : null;
}

// What the jail gives collector `c` (jail.collector), as with_collector and
// jail_of see it: `stat` says what is there.
function jail_in(c, mods, stat) {
	return jail.collector(c, { uci: mods.uci.cursor(), fs: { stat }, path: jail.PATH });
}

export function with_collector(mod, cfg, cb) {
	let c = valid_collector(mod);

	with_mods(cfg, function(mods) {
		// Every path it declares is there: one that is not is mounted once it is.
		let j = jail_in(c, mods, (p) => ({ type: 'file' }));
		let mounts = [ ...jail.COMMON, ...j.configs, ...j.paths, ...filter(values(j.commands), (p) => p != null), ...(cfg.outside_jail ?? []) ];
		let touched = [];
		let touch = (a) => push(touched, a);

		mods = { ...mods, fs: jailed_fs(mods.fs, mounts, touch) };
		if (mods.socket)
			mods.socket = jailed_socket(mods.socket, mounts, touch);

		let logs = [];
		let levels = [];
		let log = (level, msg) => { push(levels, level); push(logs, msg); };
		let session = watched_session(deps.session({ ...mods, log }), touch);
		let env = { session: () => session, clock: () => [ 0, 0 ], log };
		let run = scrape.run_one(env, session, c);

		session.close();

		let failure = contract_failure(mod.meta.name, touched, [ '/proc', '/sys', ...j.configs, ...j.paths ], mod.meta.commands ?? [], j.ubus);

		if (failure != null)
			assert.fail(failure);

		let text = exposition.render(run.families);
		let parsed = exposition.parse(text);

		if (!parsed.ok)
			assert.fail(`collector '${mod.meta.name}' wrote text that is not valid exposition: ${Result.describe(parsed)}.\n` +
				'Prometheus refuses a whole scrape over such text, every other collector\'s samples with it.\n' + text);

		cb({
			result: run.result,
			text,
			lines: text == '' ? [] : split(rtrim(text, '\n'), '\n'),
			logs,
			levels,
			// As parse() reads them back: { name, type, help, samples }.
			families: parsed.data,
		});
	}, c.id);
};

export function outcome(r) {
	return { ok: r.result.ok, none: r.result.none, error: r.result.error, lines: r.lines, logs: r.logs };
};

export function jail_of(mod, cfg) {
	let c = valid_collector(mod);
	let out;

	with_mods(cfg, function(mods) {
		out = jail_in(c, mods, (p) => (p in (cfg.files ?? [])) ? { type: 'file' } : ((p in (cfg.absent ?? [])) ? null : { type: 'directory' }));
	}, c.id);

	return out;
};
