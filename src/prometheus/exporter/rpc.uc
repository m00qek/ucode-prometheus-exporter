/**
 * The service's ubus object, `prometheus-exporter`, which rpcd serves.
 *
 * @module prometheus_exporter_rpc
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as config from 'prometheus.exporter.config';
import * as deps from 'prometheus.exporter.deps';
import * as loader from 'prometheus.exporter.loader';
import * as jail from 'prometheus.exporter.jail';
import * as scrape from 'prometheus.exporter.scrape';
import * as check from 'prometheus.exporter.check';
import * as auth from 'prometheus.exporter.auth';
import * as state from 'prometheus.exporter.state';
import * as ledger from 'prometheus.exporter.ledger';
import { scrape_env } from 'prometheus.exporter.app';
import * as jailed from 'prometheus.exporter.jailed';
import * as describer from 'prometheus.exporter.rpc.describe';
import * as validator from 'prometheus.exporter.rpc.validate';
import * as sources from 'prometheus.exporter.rpc.sources';
import { text } from 'prometheus.exporter.rpc.describe';
import { invalid_args } from 'prometheus.exporter.rpc.validate';

/**
 * What the ubus object's methods take of the system.
 *
 * @typedef {{
 *   uci: UciCursor,
 *   fs: module:fs,
 *   path: ?string,
 *   dir: ?string,
 *   apk: ?string,
 *   collectors: Collector[],
 *   skipped: ?string[],
 *   env: ScrapeEnv,
 *   ubus: UbusCapability,
 *   ledger: ?Ledger,
 *   random: function(int): ?string,
 *   uci_writer: ?function(): UciCursor,
 *   trial: ?function(Collector[], function(): Run[]): Trial
 * }} RpcSys
 */

/**
 * How deferred_json runs a command without blocking rpcd.
 *
 * @typedef {{ popen: function(string): ?FsProc, watch: function(FsProc, function()): void }} RpcIo
 */

/**
 * A request of rpcd's ucode plugins.
 *
 * @typedef {{ args: ?Object, reply: function(Object): void, defer: function(): Object }} RpcRequest
 */

/**
 * How one collector did in status's scrape.
 *
 * @typedef {{
 *   name: string,
 *   id: string,
 *   title: string,
 *   enabled: boolean,
 *   success: ?boolean,
 *   observing: ?boolean,
 *   reason: ?string,
 *   duration: ?float,
 *   error: ?string,
 *   mounts: string[],
 *   service: ?LedgerReport
 * }} CollectorStatus
 */

export const collectors = describer.collectors;
export const option_spec = describer.option_spec;
export const options_of = describer.options_of;
export const title_of = describer.title_of;
export const owners = describer.owners;
export const APK_LISTS = describer.APK_LISTS;

export const validate = validator.validate;
export const main_value = validator.main_value;
export const collector_value = validator.collector_value;
export const option_names = validator.option_names;
export const refusal = validator.refusal;
export const MAIN_OPTIONS = validator.MAIN_OPTIONS;
export const ARGS_INVALID = validator.ARGS_INVALID;

export const wireless = sources.wireless;
export const wireguard_peers = sources.wireguard_peers;
export const time_daemons = sources.time_daemons;
export const TIME_DAEMONS = sources.TIME_DAEMONS;

export const NAME = config.NAME;
export const PACKAGE = config.PACKAGE;

/** The ubus object's name: the service's. */
export const OBJECT = NAME;

/** The program rpcd runs for status, in a process of its own. */
export const STATUS_HELPER = `/usr/libexec/${NAME}/rpc-status.uc`;

/** The seconds the status helper may take before it is killed. */
export const STATUS_SECONDS = config.SCRIPT_TIMEOUT;

/** The command rpcd runs for status: the helper, under exec's watchdog. */
export const STATUS_COMMAND = deps.exec_script([ STATUS_HELPER ], STATUS_SECONDS);

/** The program that probes the collector modules for rpcd (cached_probe). */
export const PROBE_HELPER = `/usr/libexec/${NAME}/probe.uc`;

/** Where the init scripts' start links are. */
export const RC_DIR = '/etc/rc.d';

/** What status answers when its helper cannot run, or prints no reply. */
export const STATUS_FAILED = 'STATUS_FAILED';

/**
 * Whether the service is enabled and running, and where it listens.
 *
 * @param {RpcSys} sys
 * @returns {{ service: { enabled: ?boolean, boot: boolean, running: ?boolean, error: ?string, auth: ?boolean, compress: ?boolean }, listen: string[] }}
 */
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
			auth: main.ok ? main.data.auth_user != '' : null,
			compress: own.ok ? own.data.compress : null,
		},
		listen: uniq(listen),
	};
};

/**
 * The logical interfaces, in netifd's order.
 *
 * @param {RpcSys} sys
 * @returns {Object}
 */
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

/**
 * One scrape of the enabled collectors, and whether it ran in the jail.
 *
 * @param {RpcSys} sys
 * @returns {{ jailed: boolean, collectors: CollectorStatus[] }}
 */
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

/**
 * scrape_run's collectors alone.
 *
 * @param {RpcSys} sys
 * @returns {CollectorStatus[]}
 */
export function scrape_report(sys) {
	return scrape_run(sys).collectors;
};

/**
 * What the ubus object's status answers.
 *
 * @param {RpcSys} sys
 * @returns {Object}
 */
export function status(sys) {
	let report = scrape_run(sys);

	return { ...service(sys), collectors: report.collectors, jailed: report.jailed };
};

/**
 * { hash } of args.password, for auth_password.
 *
 * @param {RpcSys} sys
 * @param {?Object} args
 * @returns {Object}
 */
export function hash_password(sys, args) {
	let password = args?.password;
	let problem = auth.password_problem(password);

	if (problem)
		return invalid_args(`password: ${problem}`);

	let res = auth.hash_password(password, sys.random);

	return res.ok ? { hash: res.data } : { error: res.error, message: Result.describe(res) };
};

/** The event procd's reload triggers take of a changed config. */
export const CONFIG_CHANGE = 'config.change';

/** The file of the hash's config. */
export const AUTH_FILE = `/etc/config/${config.AUTH_CONFIG}`;

/**
 * { saved }: whether a hash of basic auth's password is saved.
 *
 * @param {RpcSys} sys
 * @returns {{ saved: boolean }}
 */
export function password(sys) {
	let hash = sys.uci.get(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password');

	return { saved: hash != null && hash != '' };
};

/**
 * Writes `hash` as the saved one, '' removing it, and commits: a Result.
 *
 * @param {RpcSys} sys
 * @param {string} hash
 * @returns {Result<boolean>}
 */
export function save_hash(sys, hash) {
	let failed = (why) => Result.err(errors.FILE_UNWRITABLE, `cannot write ${AUTH_FILE}: ${why}`);

	if (sys.fs.stat(AUTH_FILE) == null &&
	    (sys.fs.writefile(AUTH_FILE, `config ${config.AUTH_TYPE} '${config.AUTH_SECTION}'\n`) == null || !sys.fs.chmod(AUTH_FILE, 0o600)))
		return failed(sys.fs.error?.() ?? 'unknown error');

	let uci = sys.uci_writer();
	let ok = uci.set(config.AUTH_CONFIG, config.AUTH_SECTION, config.AUTH_TYPE);

	if (ok && hash != '')
		ok = uci.set(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password', hash);
	else if (ok && uci.get(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password') != null)
		ok = uci.delete(config.AUTH_CONFIG, config.AUTH_SECTION, 'auth_password');

	if (!ok || !uci.commit(config.AUTH_CONFIG))
		return failed(uci.error() ?? 'unknown error');

	return Result.ok(hash != '');
};

/**
 * { saved } of set_password: the password hashed and saved, or removed.
 *
 * @param {RpcSys} sys
 * @param {?Object} args
 * @returns {Object}
 */
export function set_password(sys, args) {
	let password = args?.password;
	let hash = '';

	if (password !== '') {
		let res = hash_password(sys, args);

		if (res.error)
			return res;
		hash = res.hash;
	}

	let res = save_hash(sys, hash);

	if (!res.ok)
		return { error: res.error, message: Result.describe(res) };

	sys.ubus.call('service', 'event', { type: CONFIG_CHANGE, data: { package: config.AUTH_CONFIG } });

	return { saved: res.data };
};

/**
 * Runs `command` without blocking rpcd, and replies with the JSON object it prints, or with what `parse` makes of its output.
 *
 * @param {RpcRequest} req
 * @param {RpcIo} io
 * @param {string} command
 * @param {?string} name
 * @param {?function(?string): Object} parse
 * @returns {Object}
 */
export function deferred_json(req, io, command, name, parse) {
	let p = io.popen(command);

	name ??= command;

	if (!p)
		return { error: STATUS_FAILED, message: `cannot run ${name}` };

	io.watch(p, function() {
		let out = p.read('all');
		let data = null;

		p.close();

		try {
			data = parse ? parse(out) : json(out);
		} catch (e) {
			data = null;
		}

		try {
			req.reply((type(data) == 'object') ? data
				: { error: STATUS_FAILED, message: `${name} printed no reply` });
		} catch (e) {
		}
	});

	return req.defer();
};

/**
 * A probe for loader.load in rpcd, run in a helper process.
 *
 * @param {module:fs} fs
 * @param {string} dir
 * @param {string} helper
 * @returns {function(string[]): Object<string, ProbeOutcome>}
 */
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

function with_ubus(make_sys, fn) {
	let sys = make_sys({ collectors: false });
	let out = fn(sys.ubus);

	sys.ubus.close();
	return out;
}

/**
 * The methods rpcd serves.
 *
 * @param {function(?{ collectors: ?boolean }): RpcSys} make_sys
 * @param {RpcIo} io
 * @returns {Object<string, { args: Object, call: function(RpcRequest): Object }>}
 */
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
			call: (req) => deferred_json(req, io, STATUS_COMMAND, STATUS_HELPER),
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
		wireless: {
			args: {},
			call: (req) => deferred_json(req, io, sources.WIRELESS_COMMAND, 'ubus call network.wireless status', sources.wireless_reply),
		},
		wireguard_peers: {
			args: {},
			call: () => sources.wireguard_peers(make_sys({ collectors: false }).uci),
		},
		time_daemons: {
			args: {},
			call: () => with_ubus(make_sys, sources.time_daemons_of),
		},
		hash_password: {
			args: { password: '' },
			call: (req) => hash_password(make_sys({ collectors: false }), req.args),
		},
		password: {
			args: {},
			call: () => password(make_sys({ collectors: false })),
		},
		set_password: {
			args: { password: '' },
			call: function(req) {
				let sys = make_sys({ collectors: false });
				let out = set_password(sys, req.args);

				sys.ubus.close();
				return out;
			},
		},
	};
};

/**
 * sys on the real system; the ledger is read only for `ledger`.
 *
 * @param {?{ collectors: ?boolean, ledger: ?boolean, probe: ?function(string[]): Object<string, ProbeOutcome> }} opts
 * @returns {RpcSys}
 */
export function system(opts) {
	let mods = deps.modules();
	let skipped = [];
	let quiet = () => null;
	let load = opts?.collectors !== false;
	let st = opts?.ledger ? state.latest(mods.fs, state.DIR) : null;

	let sys = {
		uci: mods.uci.cursor(),
		fs: mods.fs,
		path: jail.PATH,
		dir: loader.DIR,
		apk: APK_LISTS,
		collectors: load ? loader.load(mods.fs, loader.DIR, loader.import_module, (level, msg) => push(skipped, msg), opts?.probe, loader.import_modules) : [],
		skipped,
		env: scrape_env(mods, quiet),
		ubus: deps.ubus_channel(mods.ubus.connect),
		ledger: st ? ledger.parse(st.read(ledger.NAME)) : null,
		random: deps.urandom(mods.fs),
		uci_writer: deps.writable_cursor,
	};

	sys.trial = (chosen, here) => jailed.trial(sys, sys.collectors, chosen, here);

	return sys;
};
