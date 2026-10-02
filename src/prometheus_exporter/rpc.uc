'use strict';

// The service's ubus object, `prometheus-exporter`, which rpcd serves through
// /usr/share/rpcd/ucode/prometheus-exporter.uc: the exporter is a handler uhttpd
// runs per request, and publishes nothing itself. It reads with the exporter's
// own modules (loader, config, jail, scrape, check), so whoever asks (LuCI,
// `ubus call` on the router, a script) sees what the exporter sees, and writes
// nothing: settings are saved through uci.
//
//   collectors {} -> { collectors: [ collector ], skipped: [ message ] }
//   validate { main?, collectors? }
//                 -> { ok, errors: { main: { option: message }, collectors: { id: { option: message } } } }
//   status {}     -> { service: { enabled, boot, running, error, auth, compress }, listen: [ url ],
//                      collectors: [ { name, id, title, enabled, success, observing, reason,
//                                      duration, error, mounts, service } ], jailed }
//   interfaces {} -> { interfaces: [ { name, proto } ] }
//   hash_password { password } -> { hash }
//
//   collector: { name, id, title, help, enabled, package, base, options: [ option ],
//                needs, configs, commands, jail: { paths, owned, commands, mounts, problems, missing }, error }
//   option:    { name, core, type, default, help, datatype, value, set, error }
//
// options are the collector's own, in the order it declares them, then the
// core's `timeout` (core: true) when it runs programs: the seconds they get in
// each scrape. Its default is the collector's meta.timeout or else the main
// section's exec_timeout, which `default_from` names ('meta.timeout' or
// 'exec_timeout'). The core's `enabled` is the collector's own field.
//
// validate takes values as uci holds them (strings) and checks each alone, as
// the exporter would read it: an empty or missing value is unset. Options nobody
// declared, and collectors that are not installed, are ignored, as the exporter
// ignores them. The main section's options that go together (basic auth's user
// and hash, which need cert and key) are checked as if the values given were the
// whole section. A message never holds auth_password's value. Malformed
// arguments are answered { error: ARGS_INVALID, message }.
//
// status runs one scrape of the enabled collectors, as `service
// prometheus-exporter check` does: in the service's own jail where it can be
// had, which `jailed` says (prometheus_exporter.jailed), else outside it, each
// collector guarded as the service's scrapes guard it, so it ends within
// scrape_timeout whatever a collector does. rpcd runs it in a process of its
// own (rpc-status.uc), so that collectors can call the ubus objects rpcd
// itself serves (wireguard, luci) and other requests are answered meanwhile.
// A collector with nothing to observe (its hardware, kernel feature or
// service is not there) succeeds, with `observing` false and `reason` saying
// why; any other that ran has `observing` true. A collector's `service` is
// what the service's own scrapes found of it, from its running instance's
// ledger (prometheus_exporter.ledger's report: { estimate, quarantined,
// reason, retry_in, late }), or null; the scrape status runs is its own, and
// runs a quarantined collector all the same.
//
// interfaces lists the logical interfaces netifd has (`network.interface
// dump`), which the main section's listen_interface names: their names and
// protocols, and nothing else. It never reads /etc/config/network, which holds
// secrets, so a caller allowed this object alone still gets them. A failed call
// is answered { error, message }.
//
// hash_password makes the SHA-512-crypt hash of a password, freshly salted,
// that auth_password takes: rpcd runs it, unjailed, and logs neither. A
// password it does not take is answered { error: ARGS_INVALID, message }. No
// method's reply holds the hash of the config.
//
// sys: { uci: a cursor, fs: { stat, glob, readfile }, path: the PATH commands are
//        found on, dir: the collectors' directory, apk: apk's per-package file
//        lists, collectors: the loaded ones, skipped: what the loader logged,
//        env: a scrape env (prometheus_exporter.scrape), ubus: a ubus channel,
//        random(n): n random bytes, ledger: the service's ledger, or null }

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as deps from 'prometheus_exporter.deps';
import * as loader from 'prometheus_exporter.loader';
import * as jail from 'prometheus_exporter.jail';
import * as scrape from 'prometheus_exporter.scrape';
import * as check from 'prometheus_exporter.check';
import * as auth from 'prometheus_exporter.auth';
import * as state from 'prometheus_exporter.state';
import * as ledger from 'prometheus_exporter.ledger';
import { scrape_env } from 'prometheus_exporter.app';
import * as jailed from 'prometheus_exporter.jailed';

// The service's names follow from config.NAME, its packages' from config.PACKAGE.
export const NAME = config.NAME;
export const PACKAGE = config.PACKAGE;
export const OBJECT = NAME;
export const STATUS_HELPER = `/usr/libexec/${NAME}/rpc-status.uc`;
export const PROBE_HELPER = `/usr/libexec/${NAME}/probe.uc`;

export const APK_LISTS = '/lib/apk/packages';
export const RC_DIR = '/etc/rc.d';

export const ARGS_INVALID = 'ARGS_INVALID';
export const STATUS_FAILED = 'STATUS_FAILED';

// The main section's options: the init script's, then the exporter's.
export const MAIN_OPTIONS = [ ...keys(config.SERVICE_OPTIONS), ...keys(config.MAIN_OPTIONS) ];

function text(v) {
	return (type(v) == 'string' && v != '') ? v : null;
}

// One option of meta.options, in either shape: a bare default (`stations: true`),
// or { default, help, datatype }. datatype names LuCI's datatypes, and 'regex'.
export function option_spec(name, decl) {
	let spec = (type(decl) == 'object') ? decl : { default: decl };

	return {
		name,
		core: false,
		type: type(spec.default),
		default: spec.default,
		help: text(spec.help),
		datatype: text(spec.datatype),
	};
};

// meta.options as a list, in the order the collector declares them.
export function options_of(meta) {
	let options = meta.options ?? {};

	return map(keys(options), (name) => option_spec(name, options[name]));
};

// A short label: meta.title, or the collector's name.
export function title_of(meta) {
	return text(meta.title) ?? meta.name;
};

function is_unset(value) {
	return value == null || value === '';
}

// A cursor over the exporter's config with one section, holding `values`: what
// the exporter would read of those values alone.
function lone_section(name, stype, values) {
	let s = { '.name': name, '.type': stype, '.anonymous': false };

	for (let k, v in values)
		if (!is_unset(v))
			s[k] = v;

	let get_all = (pkg, sid) => (pkg == NAME && sid == name) ? s : null;

	return {
		load: (pkg) => pkg == NAME,
		get_all,
		get: (pkg, sid, opt) => (opt == null) ? get_all(pkg, sid)?.['.type'] : get_all(pkg, sid)?.[opt],
		foreach: function(pkg, t, cb) {
			if (pkg == NAME && (t == null || t == stype))
				cb(s);
		},
	};
}

// The details of a CONFIG_INVALID, less the option's name the field already shows.
function message(name, res) {
	let d = (type(res.details) == 'string') ? res.details : Result.describe(res);
	let prefix = `${name}: `;

	return (substr(d, 0, length(prefix)) == prefix) ? substr(d, length(prefix)) : d;
}

// What the exporter makes of `value` for option `name` of the main section:
// a Result of the typed value, the default when it is unset.
export function main_value(name, value) {
	let uci = lone_section('main', NAME, { [name]: value });
	let svc = config.service_values(uci);
	let own = config.main(uci);

	if (!svc.ok)
		return svc;
	if (!own.ok)
		return own;

	return Result.ok((name in keys(config.SERVICE_OPTIONS)) ? svc.data[name] : own.data[name]);
};

// What the exporter makes of `value` for option `name` (or the core's enabled
// or timeout) of collector `c`: a Result of the typed value, the default when
// it is unset. The section is read alone: an unset timeout is meta.timeout's,
// or exec_timeout's default.
export function collector_value(c, name, value) {
	let uci = lone_section(c.id, 'collector', { [name]: value });
	let res = config.settings(uci, c.id, c.meta);

	if (!res.ok)
		return res;

	switch (name) {
	case 'enabled': return Result.ok(config.enabled(uci, c.id));
	case 'timeout': return Result.ok(res.data.timeout);
	}

	return Result.ok(res.data.options[name]);
};

// The option names a collector's section takes: the core's, then its own.
export function option_names(c) {
	return [ ...keys(config.core(c.meta, config.EXEC_TIMEOUT)), ...keys(c.meta.options ?? {}) ];
};

// { path: package } for the files of the exporter's packages: apk keeps a list
// of each package's files.
export function owners(fs, dir) {
	let out = {};

	for (let list in fs.glob(`${dir}/${PACKAGE}*.list`) ?? []) {
		let pkg = replace(substr(list, length(dir) + 1), /\.list$/, '');

		for (let path in split(fs.readfile(list) ?? '', '\n'))
			if (path != '')
				out[path] = pkg;
	}

	return out;
};

function option_entry(c, spec, section) {
	let set = (spec.name in keys(section));
	let res = collector_value(c, spec.name, set ? section[spec.name] : null);

	return {
		...spec,
		value: res.ok ? res.data : section[spec.name],
		set,
		error: res.ok ? null : message(spec.name, res),
	};
}

// The core's timeout of a collector that runs programs, whose default follows
// the configuration as saved: meta.timeout, or else the main section's
// exec_timeout.
function timeout_entry(sys, c, section) {
	let set = ('timeout' in keys(section));
	let fallback = config.default_timeout(sys.uci, c.meta);
	let res = set ? collector_value(c, 'timeout', section.timeout) : Result.ok(fallback);

	return {
		name: 'timeout',
		core: true,
		type: 'int',
		default: fallback,
		default_from: (c.meta.timeout != null) ? 'meta.timeout' : 'exec_timeout',
		help: config.TIMEOUT.help,
		datatype: config.TIMEOUT.datatype,
		value: res.ok ? res.data : section.timeout,
		set,
		error: res.ok ? null : message('timeout', res),
	};
}

function collector_entry(sys, c, owner_of) {
	let meta = c.meta;
	let j = jail.collector(c, sys);
	let owner = owner_of[`${sys.dir ?? loader.DIR}/${c.id}.uc`];
	let section = sys.uci.get_all(NAME, c.id);

	if (type(section) != 'object' || section['.type'] != 'collector')
		section = {};

	return {
		name: meta.name,
		id: c.id,
		title: title_of(meta),
		help: meta.help,
		enabled: j.enabled,
		package: owner ?? null,
		base: (owner == null) ? null : owner == PACKAGE,
		options: [
			...map(options_of(meta), (spec) => option_entry(c, spec, section)),
			...(('exec' in meta.needs) ? [ timeout_entry(sys, c, section) ] : []),
		],
		needs: meta.needs,
		configs: meta.configs ?? [],
		commands: meta.commands ?? [],
		jail: { paths: j.paths, owned: j.owned, commands: j.commands, mounts: j.mounts, problems: j.problems, missing: j.missing },
		// The section's first invalid option (or enabled), as the exporter reports it.
		error: j.options.ok ? null : Result.describe(j.options),
	};
}

export function collectors(sys) {
	let owner_of = owners(sys.fs, sys.apk ?? APK_LISTS);

	return {
		collectors: map(sys.collectors, (c) => collector_entry(sys, c, owner_of)),
		skipped: sys.skipped ?? [],
	};
};

function invalid_args(msg) {
	return { error: ARGS_INVALID, message: msg };
}

export function validate(sys, args) {
	let main = args?.main ?? {};
	let given = args?.collectors ?? {};
	let errors = { main: {}, collectors: {} };
	let by_id = {};

	if (type(main) != 'object' || type(given) != 'object')
		return invalid_args('main and collectors must be objects');

	let typed = config.defaults(config.SERVICE_OPTIONS);

	for (let name, value in main) {
		if (!(name in MAIN_OPTIONS) || is_unset(value))
			continue;

		let res = main_value(name, value);
		if (res.ok)
			typed[name] = res.data;
		else
			errors.main[name] = message(name, res);
	}

	for (let name, msg in config.together(typed))
		errors.main[name] ??= msg;

	for (let c in sys.collectors)
		by_id[c.id] = c;

	for (let id, values in given) {
		let c = by_id[id];

		if (c == null)
			continue;
		if (type(values) != 'object')
			return invalid_args(`collectors.${id} must be an object`);

		let names = option_names(c);

		for (let name, value in values) {
			if (!(name in names) || is_unset(value))
				continue;

			let res = collector_value(c, name, value);
			if (!res.ok) {
				errors.collectors[id] ??= {};
				errors.collectors[id][name] = message(name, res);
			}
		}
	}

	let ok = !length(errors.main) && !length(errors.collectors);

	return { ok, errors };
};

// Whether the service is enabled and running, and where it listens: procd's
// instances, the init script's start link and the main section's `enabled`.
export function service(sys) {
	let res = sys.ubus.call('service', 'list', { name: NAME });
	let main = config.service(sys.uci);
	let own = config.main(sys.uci);
	let instances = res.ok ? check.exporters(values(res.data?.[NAME]?.instances ?? {})) : [];
	let running = filter(instances, (i) => i?.running == true);
	let listen = [];

	for (let i in running)
		push(listen, ...check.listening(i.command ?? []));

	return {
		service: {
			enabled: main.ok ? main.data.enabled : null,
			boot: length(sys.fs.glob(`${RC_DIR}/S*${NAME}`) ?? []) > 0,
			running: res.ok ? length(running) > 0 : null,
			error: res.ok ? null : Result.describe(res),
			// Whether a scrape logs in, and is compressed when asked, as configured.
			auth: main.ok ? main.data.auth_user != '' : null,
			compress: own.ok ? own.data.compress : null,
		},
		listen: uniq(listen),
	};
};

// The logical interfaces, in netifd's order.
export function interfaces(sys) {
	let res = sys.ubus.call('network.interface', 'dump', {});

	if (!res.ok)
		return { error: res.error, message: Result.describe(res) };

	let out = [];

	for (let i in res.data?.interface ?? [])
		if (type(i?.interface) == 'string' && i.interface != '')
			push(out, { name: i.interface, proto: text(i.proto) });

	return { interfaces: out };
};

// One scrape of the enabled collectors: how each did, whether it had
// something to observe (and why not), and what the jail gives it.
// { jailed, collectors }: scrape_report's collectors, and whether they ran in
// the service's jail.
export function scrape_run(sys) {
	let chosen = filter(sys.collectors, (c) => config.enabled(sys.uci, c.id));
	let t = check.trial(sys, chosen);
	let runs = {};

	for (let r in t.runs)
		runs[r.id] = r;

	return { jailed: t.jailed, collectors: map(sys.collectors, function(c) {
		let r = runs[c.id];
		let j = jail.collector(c, sys);

		return {
			name: c.meta.name,
			id: c.id,
			title: title_of(c.meta),
			enabled: r != null,
			success: r ? r.result.ok : null,
			observing: r ? !Result.is_none(r.result) : null,
			reason: (r && Result.is_none(r.result)) ? r.result.none : null,
			duration: r ? r.duration : null,
			error: (r && !r.result.ok) ? Result.describe(r.result) : null,
			mounts: j.enabled ? j.mounts : [],
			service: sys.ledger ? ledger.report(sys.ledger, c.id) : null,
		};
	}) };
};

export function scrape_report(sys) {
	return scrape_run(sys).collectors;
};

export function status(sys) {
	let report = scrape_run(sys);

	return { ...service(sys), collectors: report.collectors, jailed: report.jailed };
};

// { hash } of args.password, for auth_password.
export function hash_password(sys, args) {
	let password = args?.password;
	let problem = auth.password_problem(password);

	if (problem)
		return invalid_args(`password: ${problem}`);

	let res = auth.hash_password(password, sys.random);

	return res.ok ? { hash: res.data } : { error: res.error, message: Result.describe(res) };
};

// Runs `command` without blocking rpcd, and replies with the JSON object it
// prints. io: { popen(command) -> a handle, or null; watch(handle, cb): calls
// cb once the handle can be read }. The reply is { error: STATUS_FAILED,
// message } when the command cannot start or prints no object.
export function deferred_json(req, io, command) {
	let p = io.popen(command);

	if (!p)
		return { error: STATUS_FAILED, message: `cannot run ${command}` };

	io.watch(p, function() {
		let out = p.read('all');
		let data = null;

		p.close();

		try {
			data = json(out);
		} catch (e) {
			data = null;
		}

		// rpcd has answered already if the command outlived its request timeout.
		try {
			req.reply((type(data) == 'object') ? data
				: { error: STATUS_FAILED, message: `${command} printed no reply` });
		} catch (e) {
		}
	});

	return req.defer();
};

// A probe for loader.load in rpcd (prometheus_exporter.runner's probe), which
// rpcd itself must not run: a collector module whose top level never returns
// would hang rpcd, and every LuCI page with it, and rpcd's own event loop is
// not one to run another inside. So `helper` (PROBE_HELPER) probes the modules
// in a process of its own, which prints what runner.probe found as JSON, and
// rpcd waits for it, a module's LOAD_TIMEOUT at most; and it does so once for
// each version of a module, by its inode, size and change time in `dir`
// (loader.DIR): a reload of rpcd forgets them all. fs: { stat, popen }.
export function cached_probe(fs, dir, helper) {
	let known = {};

	return function(ids) {
		let out = {};
		let need = [];
		let sigs = {};

		for (let id in ids) {
			let st = fs.stat(`${dir}/${id}.uc`);

			sigs[id] = st ? `${st.inode}:${st.size}:${st.mtime}` : null;
			if (sigs[id] != null && known[id]?.sig == sigs[id])
				out[id] = known[id].res;
			else
				push(need, id);
		}

		if (!length(need))
			return out;

		let p = fs.popen(`${helper} ${join(' ', need)} 2>/dev/null`, 'r');
		let text = p?.read('all');
		let found = null;

		p?.close();
		try {
			found = json(text);
		} catch (e) {
			found = null;
		}

		for (let id in need) {
			let res = found?.[id] ?? { ok: false, hung: false, error: `${helper} said nothing of it` };

			out[id] = res;
			if (found?.[id] != null)
				known[id] = { sig: sigs[id], res };
		}

		return out;
	};
};

// The methods rpcd serves. make_sys(opts) gives a fresh sys per call: rpcd
// outlives any number of commits and package changes; opts.collectors false
// leaves the collectors unloaded. io as deferred_json's.
export function methods(make_sys, io) {
	return {
		collectors: {
			args: {},
			call: () => collectors(make_sys()),
		},
		validate: {
			args: { main: {}, collectors: {} },
			call: (req) => validate(make_sys(), req.args),
		},
		status: {
			args: {},
			call: (req) => deferred_json(req, io, `${STATUS_HELPER} 2>/dev/null`),
		},
		interfaces: {
			args: {},
			call: function() {
				let sys = make_sys({ collectors: false });
				let out = interfaces(sys);

				sys.ubus.close();
				return out;
			},
		},
		hash_password: {
			args: { password: '' },
			call: (req) => hash_password(make_sys({ collectors: false }), req.args),
		},
	};
};

// sys on the real system. Its committed configuration only, as the exporter
// reads it. opts.collectors false leaves the collectors unloaded; opts.probe
// is loader.load's (cached_probe's in rpcd). Its scrapes run each collector
// in a process of its own (scrape.trial).
export function system(opts) {
	let mods = deps.modules();
	let skipped = [];
	let quiet = () => null;
	let load = opts?.collectors !== false;
	let st = state.latest(mods.fs, state.DIR);

	let sys = {
		uci: mods.uci.cursor(),
		fs: mods.fs,
		path: jail.PATH,
		dir: loader.DIR,
		apk: APK_LISTS,
		collectors: load ? loader.load(mods.fs, loader.DIR, loader.import_module, (level, msg) => push(skipped, msg), opts?.probe) : [],
		skipped,
		env: scrape_env(mods, quiet),
		ubus: deps.ubus_channel(mods.ubus.connect),
		ledger: st ? ledger.parse(st.read(ledger.NAME)) : null,
		random: function(n) {
			let f = mods.fs.open('/dev/urandom', 'r');
			let bytes = f?.read(n);

			f?.close();
			return bytes;
		},
	};

	// In the service's jail, where it can be had (check.trial).
	sys.trial = (chosen, here) => jailed.trial(sys, sys.collectors, chosen, here);

	return sys;
};
