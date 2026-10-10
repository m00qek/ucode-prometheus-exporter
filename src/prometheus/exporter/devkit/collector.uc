/**
 * The devkit's collector check, for a collector's tests under utest.
 *
 * @module prometheus_exporter_devkit_collector
 */

'use strict';

import { mock, assert } from 'utest';
import * as deps from 'prometheus.exporter.deps';
import * as loader from 'prometheus.exporter.loader';
import * as scrape from 'prometheus.exporter.scrape';
import * as exposition from 'prometheus.exporter.exposition';
import * as config from 'prometheus.exporter.config';
import * as jail from 'prometheus.exporter.jail';
import * as codes from 'prometheus.exporter.errors';
import * as Result from 'prometheus.exporter.result';

const real_fs = require('fs');

/** The modules a test's utest config mocks. */
export const MOCKED = [ 'fs', 'ubus', 'uci', 'rtnl', 'nl80211', 'socket' ];

/**
 * What with_collector() and jail_of() take of a test, every key optional.
 *
 * @typedef {Object} CollectorTestConfig
 */

/**
 * What with_collector() hands its callback.
 *
 * @typedef {{ result: Result, text: string, lines: string[], logs: string[], levels: string[], families: Object[] }} CollectorRun
 */

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

/**
 * Injects utest's mocks and calls cb with module-shaped objects for deps.session().
 *
 * @param {CollectorTestConfig} cfg
 * @param {function(Object): void} cb
 * @param {?string} id
 */
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

function valid_collector(mod) {
	let id = loader.id_of(mod?.meta?.name ?? '');
	let valid = loader.validate(id, mod);

	if (!valid.ok)
		assert.fail(`collector '${mod?.meta?.name}' has a meta the loader refuses: ${Result.describe(valid)}.\n` +
			'The exporter leaves it out, logged at err: fix its meta.');

	return valid.data;
}

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

function above(mounts, p) {
	let prefix = (p == '/') ? '/' : p + '/';
	let names = {};

	for (let m in mounts)
		if (substr(m, 0, length(prefix)) == prefix && substr(m, -1) != '*')
			names[split(substr(m, length(prefix)), '/')[0]] = true;

	return length(names) ? sort(keys(names)) : null;
}

function glob_base(pattern) {
	let parts = [];

	for (let part in split(pattern, '/')) {
		if (match(part, /[*?[]/))
			break;
		push(parts, part);
	}

	return normal(join('/', parts) || '/');
}

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

			let all = fs.glob(pattern, ...rest) ?? [];
			let kept = filter(all, (f) => inside(mounts, normal(f) ?? ''));

			return outside('glob', pattern, kept);
		},
	};
}

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

						if (!r.ok && r.error == codes.COMMAND_NOT_ALLOWED)
							touched({ kind: 'exec', program: argv?.[0] });

						return r;
					},
				};

			if (ubus)
				d.ubus = {
					...ubus,
					call: function(object, method, ...rest) {
						let r = ubus.call(object, method, ...rest);

						if (!r.ok && r.error == codes.UBUS_NOT_ALLOWED)
							touched({ kind: 'ubus', object, method });

						return r;
					},
				};

			return Result.ok(d);
		},
	};
}

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

function jail_in(c, mods, stat) {
	return jail.collector(c, { uci: mods.uci.cursor(), fs: { stat }, path: jail.PATH });
}

/**
 * Runs collector module `mod` as a scrape does, held to its contract, and calls cb.
 *
 * @param {CollectorModule} mod
 * @param {CollectorTestConfig} cfg
 * @param {function(CollectorRun): void} cb
 */
export function with_collector(mod, cfg, cb) {
	let c = valid_collector(mod);

	with_mods(cfg, function(mods) {
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
			families: parsed.data,
		});
	}, c.id);
};

/**
 * What a test checks of a with_collector run that fails or has nothing to observe.
 *
 * @param {CollectorRun} r
 * @returns {{ ok: boolean, none: ?string, error: ?string, lines: string[], logs: string[] }}
 */
export function outcome(r) {
	return { ok: r.result.ok, none: r.result.none, error: r.result.error, lines: r.lines, logs: r.logs };
};

/**
 * What the exporter's jail gives collector module `mod`.
 *
 * @param {CollectorModule} mod
 * @param {CollectorTestConfig} cfg
 * @returns {Object}
 */
export function jail_of(mod, cfg) {
	let c = valid_collector(mod);
	let out;

	with_mods(cfg, function(mods) {
		out = jail_in(c, mods, (p) => (p in (cfg.files ?? [])) ? { type: 'file' } : ((p in (cfg.absent ?? [])) ? null : { type: 'directory' }));
	}, c.id);

	return out;
};

/**
 * What the loader and `collector check` refuse of a collector module's text.
 *
 * @param {?string} text
 * @returns {string[]}
 */
export function module_problems(text) {
	if (text == null)
		return [ 'the module cannot be read' ];

	let why = loader.refusal(text);

	if (why != null)
		return split(why, '; ');

	why = loader.purity_problem(text);

	return (why == null) ? [] : split(why, '; ');
};

/**
 * Fails the test when the collector module at `path` has a module_problems() problem.
 *
 * @param {string} path
 */
export function assert_module(path) {
	let problems = module_problems(real_fs.readfile(path));

	if (length(problems))
		assert.fail(`${path}: the exporter leaves this collector out:\n- ${join('\n- ', problems)}`);
};
