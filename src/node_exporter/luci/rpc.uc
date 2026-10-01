'use strict';

// The ubus object of luci-app-prometheus-node-exporter-ucode, which rpcd serves
// through /usr/share/rpcd/ucode/prometheus-node-exporter-ucode.uc. It reads with
// the exporter's own modules (loader, config, jail, scrape, check), so LuCI sees
// what the exporter sees, and writes nothing: LuCI saves the settings through
// uci, as every page does.
//
//   collectors {} -> { collectors: [ collector ], skipped: [ message ] }
//   validate { main?, collectors? }
//                 -> { ok, errors: { main: { option: message }, collectors: { id: { option: message } } } }
//   status {}     -> { service: { enabled, boot, running, error }, listen: [ url ],
//                      collectors: [ { name, id, title, enabled, success, duration, error, mounts } ] }
//
//   collector: { name, id, title, help, enabled, package, base, options: [ option ],
//                needs, configs, commands, jail: { paths, commands, mounts, problems, missing }, error }
//   option:    { name, type, default, help, datatype, value, set, error }
//
// validate takes values as uci holds them (strings) and checks each alone, as
// the exporter would read it: an empty or missing value is unset. Options nobody
// declared, and collectors that are not installed, are ignored, as the exporter
// ignores them. Malformed arguments are answered { error: ARGS_INVALID, message }.
//
// status runs one scrape of the enabled collectors, outside the jail, as
// `service prometheus-node-exporter-ucode check` does: rpcd runs it in a process
// of its own (luci-status.uc), so that collectors can call the ubus objects rpcd
// itself serves (wireguard, luci) and other requests are answered meanwhile.
//
// sys: { uci: a cursor, fs: { stat, glob, readfile }, path: the PATH commands are
//        found on, dir: the collectors' directory, apk: apk's per-package file
//        lists, collectors: the loaded ones, skipped: what the loader logged,
//        env: a scrape env (node_exporter.scrape), ubus: a ubus channel }

import * as Result from 'node_exporter.result';
import * as config from 'node_exporter.config';
import * as deps from 'node_exporter.deps';
import * as loader from 'node_exporter.loader';
import * as jail from 'node_exporter.jail';
import * as scrape from 'node_exporter.scrape';
import * as check from 'node_exporter.check';

// The names the rename of the exporter changes all follow from its package's.
export const PACKAGE = config.PACKAGE;
export const OBJECT = PACKAGE;
export const STATUS_HELPER = `/usr/libexec/${PACKAGE}/luci-status.uc`;

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

	let get_all = (pkg, sid) => (pkg == PACKAGE && sid == name) ? s : null;

	return {
		load: (pkg) => pkg == PACKAGE,
		get_all,
		get: (pkg, sid, opt) => (opt == null) ? get_all(pkg, sid)?.['.type'] : get_all(pkg, sid)?.[opt],
		foreach: function(pkg, t, cb) {
			if (pkg == PACKAGE && (t == null || t == stype))
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
	let uci = lone_section('main', PACKAGE, { [name]: value });
	let svc = config.service(uci);
	let own = config.main(uci);

	if (!svc.ok)
		return svc;
	if (!own.ok)
		return own;

	return Result.ok((name in keys(config.SERVICE_OPTIONS)) ? svc.data[name] : own.data[name]);
};

// What the exporter makes of `value` for option `name` (or `enabled`) of
// collector `c`: a Result of the typed value, the default when it is unset.
export function collector_value(c, name, value) {
	let uci = lone_section(c.id, 'collector', { [name]: value });
	let res = config.collector(uci, c.id, c.meta.options);

	if (!res.ok)
		return res;

	return Result.ok((name == 'enabled') ? config.enabled(uci, c.id) : res.data[name]);
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

function collector_entry(sys, c, owner_of) {
	let meta = c.meta;
	let j = jail.collector(c, sys);
	let owner = owner_of[`${sys.dir ?? loader.DIR}/${c.id}.uc`];
	let section = sys.uci.get_all(PACKAGE, c.id);

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
		options: map(options_of(meta), (spec) => option_entry(c, spec, section)),
		needs: meta.needs,
		configs: meta.configs ?? [],
		commands: meta.commands ?? [],
		jail: { paths: j.paths, commands: j.commands, mounts: j.mounts, problems: j.problems, missing: j.missing },
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

	for (let name, value in main) {
		if (!(name in MAIN_OPTIONS) || is_unset(value))
			continue;

		let res = main_value(name, value);
		if (!res.ok)
			errors.main[name] = message(name, res);
	}

	for (let c in sys.collectors)
		by_id[c.id] = c;

	for (let id, values in given) {
		let c = by_id[id];

		if (c == null)
			continue;
		if (type(values) != 'object')
			return invalid_args(`collectors.${id} must be an object`);

		let names = [ 'enabled', ...keys(c.meta.options ?? {}) ];

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
	let res = sys.ubus.call('service', 'list', { name: PACKAGE });
	let main = config.service(sys.uci);
	let instances = res.ok ? values(res.data?.[PACKAGE]?.instances ?? {}) : [];
	let running = filter(instances, (i) => i?.running == true);
	let listen = [];

	for (let i in running)
		push(listen, ...check.listening(i.command ?? []));

	return {
		service: {
			enabled: main.ok ? main.data.enabled : null,
			boot: length(sys.fs.glob(`${RC_DIR}/S*${PACKAGE}`) ?? []) > 0,
			running: res.ok ? length(running) > 0 : null,
			error: res.ok ? null : Result.describe(res),
		},
		listen: uniq(listen),
	};
};

// One scrape of the enabled collectors: how each did, and what the jail gives it.
export function scrape_report(sys) {
	let session = sys.env.session();
	let runs = {};

	for (let c in sys.collectors)
		if (config.enabled(sys.uci, c.id))
			runs[c.id] = scrape.run_one(sys.env, session, c);

	session.close();

	return map(sys.collectors, function(c) {
		let r = runs[c.id];
		let j = jail.collector(c, sys);

		return {
			name: c.meta.name,
			id: c.id,
			title: title_of(c.meta),
			enabled: r != null,
			success: r ? r.result.ok : null,
			duration: r ? r.duration : null,
			error: (r && !r.result.ok) ? Result.describe(r.result) : null,
			mounts: j.enabled ? j.mounts : [],
		};
	});
};

export function status(sys) {
	return { ...service(sys), collectors: scrape_report(sys) };
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

// The methods rpcd serves. make_sys() gives a fresh sys per call: rpcd outlives
// any number of commits and package changes. io as deferred_json's.
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
	};
};

// sys on the real system. Its committed configuration only, as the exporter
// reads it.
export function system() {
	let mods = deps.modules();
	let skipped = [];
	let quiet = () => null;

	return {
		uci: mods.uci.cursor(),
		fs: mods.fs,
		path: jail.PATH,
		dir: loader.DIR,
		apk: APK_LISTS,
		collectors: loader.load(mods.fs, loader.DIR, loader.import_module, (msg) => push(skipped, msg)),
		skipped,
		env: {
			session: () => deps.session({ ...mods, log: quiet }),
			clock: () => clock(true),
			log: quiet,
		},
		ubus: deps.ubus_channel(mods.ubus.connect),
	};
};
