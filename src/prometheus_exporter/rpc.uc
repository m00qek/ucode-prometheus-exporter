/**
 * The service's ubus object, `prometheus-exporter`, which rpcd serves through
 * /usr/share/rpcd/ucode/prometheus-exporter.uc: the exporter is a handler uhttpd
 * runs per request, and publishes nothing itself. It reads with the exporter's
 * own modules (loader, config, jail, scrape, check), so whoever asks (LuCI,
 * `ubus call` on the router, a script) sees what the exporter sees, and writes
 * nothing: settings are saved through uci.
 *
 *   collectors {} -> { collectors: [ collector ], skipped: [ message ] }
 *   validate { main?, collectors? }
 *                 -> { ok, errors: { main: { option: refusal }, collectors: { id: { option: refusal } } } }
 *   status {}     -> { service: { enabled, boot, running, error, auth, compress }, listen: [ url ],
 *                      collectors: [ { name, id, title, enabled, success, observing, reason,
 *                                      duration, error, mounts, service } ], jailed }
 *   interfaces {} -> { interfaces: [ { name, proto } ] }
 *   hash_password { password } -> { hash }
 *
 * A collector and its options are as prometheus_exporter.rpc.describe
 * describes them, and validate checks values as prometheus_exporter.rpc.validate
 * says: a refusal is the code of what is wrong (prometheus_exporter.config's
 * PROBLEMS), its arguments, and its English as `message`. This module is the
 * facade of rpc/: what others take of those it exports, under the names
 * below.
 *
 * status runs one scrape of the enabled collectors, as `service
 * prometheus-exporter check` does: in the service's own jail where it can be
 * had, which `jailed` says (prometheus_exporter.jailed), else outside it, each
 * collector guarded as the service's scrapes guard it, so it ends within
 * scrape_timeout whatever a collector does. rpcd runs it in a process of its
 * own (rpc-status.uc), so that collectors can call the ubus objects rpcd
 * itself serves (wireguard, luci) and other requests are answered meanwhile.
 * A collector with nothing to observe (its hardware, kernel feature or
 * service is not there) succeeds, with `observing` false and `reason` saying
 * why; any other that ran has `observing` true. A collector's `service` is
 * what the service's own scrapes found of it, from its running instance's
 * ledger (prometheus_exporter.ledger's report: { estimate, quarantined,
 * reason, retry_in, late }), or null; the scrape status runs is its own, and
 * runs a quarantined collector all the same.
 *
 * interfaces lists the logical interfaces netifd has (`network.interface
 * dump`), which the main section's listen_interface names: their names and
 * protocols, and nothing else. It never reads /etc/config/network, which holds
 * secrets, so a caller allowed this object alone still gets them. A failed call
 * is answered { error, message }.
 *
 * hash_password makes the SHA-512-crypt hash of a password, freshly salted,
 * that auth_password takes: rpcd runs it, unjailed, and logs neither. A
 * password it does not take is answered { error: ARGS_INVALID, message }. No
 * method's reply holds the hash of the config.
 *
 * sys: { uci: a cursor, fs: { stat, glob, readfile }, path: the PATH commands are
 *        found on, dir: the collectors' directory, apk: apk's per-package file
 *        lists, collectors: the loaded ones, skipped: what the loader logged,
 *        env: a scrape env (prometheus_exporter.scrape), ubus: a ubus channel,
 *        random(n): n random bytes, ledger: the service's ledger, or null }
 *
 * @module prometheus_exporter_rpc
 */

'use strict';

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
import * as describer from 'prometheus_exporter.rpc.describe';
import * as validator from 'prometheus_exporter.rpc.validate';
import { text } from 'prometheus_exporter.rpc.describe';
import { invalid_args } from 'prometheus_exporter.rpc.validate';

/**
 * What the ubus object's methods take of the system, as the module's top
 * comment says: sys.trial runs the chosen collectors in the service's jail
 * (prometheus_exporter.jailed), here() where it cannot be had.
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
 *   trial: ?function(Collector[], function(): Run[]): Trial
 * }} RpcSys
 */

/**
 * How deferred_json runs a command without blocking rpcd: popen(command), a
 * handle or null, and watch(handle, cb), which calls cb once the handle can
 * be read.
 *
 * @typedef {{ popen: function(string): ?FsProc, watch: function(FsProc, function()): void }} RpcIo
 */

/**
 * A request of rpcd's ucode plugins: its arguments, reply() to answer it
 * later, and defer(), what a method returns to answer it later.
 *
 * @typedef {{ args: ?Object, reply: function(Object): void, defer: function(): Object }} RpcRequest
 */

/**
 * How one collector did in status's scrape, as scrape_run lists it: its
 * names, whether it is enabled and succeeded, whether it had something to
 * observe and why not, how long it took, its error, its jail's mounts, and
 * the service's own scrapes' report of it (ledger.report).
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

// `collectors`: each collector as the exporter sees it, its options in
// either shape of meta.options, its title, and the packages of its files.
export const collectors = describer.collectors;
export const option_spec = describer.option_spec;
export const options_of = describer.options_of;
export const title_of = describer.title_of;
export const owners = describer.owners;
export const APK_LISTS = describer.APK_LISTS;

// `validate`, what the exporter makes of a value of the main section or of a
// collector's, the options a collector's section takes, what it answers of a
// value it refuses, the main section's, and what malformed arguments are
// answered.
export const validate = validator.validate;
export const main_value = validator.main_value;
export const collector_value = validator.collector_value;
export const option_names = validator.option_names;
export const refusal = validator.refusal;
export const MAIN_OPTIONS = validator.MAIN_OPTIONS;
export const ARGS_INVALID = validator.ARGS_INVALID;

// The service's names follow from config.NAME, its packages' from config.PACKAGE.
export const NAME = config.NAME;
export const PACKAGE = config.PACKAGE;

/**
 * The ubus object's name: the service's.
 *
 * @type {string}
 */
export const OBJECT = NAME;

/**
 * The program rpcd runs for status, in a process of its own.
 *
 * @type {string}
 */
export const STATUS_HELPER = `/usr/libexec/${NAME}/rpc-status.uc`;

/**
 * The seconds the status helper may take before it is killed, with every
 * process it started: what uhttpd gives a scrape. Its scrape has the main
 * section's scrape_timeout, at most as long, and every collector of it is
 * stopped by then; this is for anything else: so no helper outlives it, and
 * a LuCI page refreshed again and again leaves none behind.
 *
 * @type {int}
 */
export const STATUS_SECONDS = config.SCRIPT_TIMEOUT;

/**
 * The command rpcd runs for status: the helper, under exec's watchdog.
 *
 * @type {string}
 */
export const STATUS_COMMAND = deps.exec_script([ STATUS_HELPER ], STATUS_SECONDS);

/**
 * The program that probes the collector modules for rpcd (cached_probe).
 *
 * @type {string}
 */
export const PROBE_HELPER = `/usr/libexec/${NAME}/probe.uc`;

/**
 * Where the init scripts' start links are.
 *
 * @type {string}
 */
export const RC_DIR = '/etc/rc.d';

/**
 * What status answers when its helper cannot run, or prints no reply.
 *
 * @type {string}
 */
export const STATUS_FAILED = 'STATUS_FAILED';

/**
 * Whether the service is enabled and running, and where it listens: procd's
 * instances, the init script's start link and the main section's `enabled`.
 *
 * @param {RpcSys} sys the system.
 * @returns {{ service: { enabled: ?boolean, boot: boolean, running: ?boolean, error: ?string, auth: ?boolean, compress: ?boolean }, listen: string[] }}
 *   the service, and the URLs it listens on.
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
			// Whether a scrape logs in, and is compressed when asked, as configured.
			auth: main.ok ? main.data.auth_user != '' : null,
			compress: own.ok ? own.data.compress : null,
		},
		listen: uniq(listen),
	};
};

/**
 * The logical interfaces, in netifd's order.
 *
 * @param {RpcSys} sys the system.
 * @returns {Object} { interfaces: [ { name, proto } ] }, or { error, message }.
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
 * One scrape of the enabled collectors: how each did, whether it had
 * something to observe (and why not), and what the jail gives it.
 * { jailed, collectors }: scrape_report's collectors, and whether they ran in
 * the service's jail.
 *
 * @param {RpcSys} sys the system.
 * @returns {{ jailed: boolean, collectors: CollectorStatus[] }} each
 *   installed collector, and whether they ran in the jail.
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
 * @param {RpcSys} sys the system.
 * @returns {CollectorStatus[]} each installed collector.
 */
export function scrape_report(sys) {
	return scrape_run(sys).collectors;
};

/**
 * What the ubus object's status answers: the service, where it listens, how
 * each collector did in one scrape, and whether they ran in the jail.
 *
 * @param {RpcSys} sys the system.
 * @returns {Object} { service, listen, collectors, jailed }.
 */
export function status(sys) {
	let report = scrape_run(sys);

	return { ...service(sys), collectors: report.collectors, jailed: report.jailed };
};

/**
 * { hash } of args.password, for auth_password.
 *
 * @param {RpcSys} sys the system: its random.
 * @param {?Object} args the method's arguments: { password }.
 * @returns {Object} { hash }, or { error, message }.
 */
export function hash_password(sys, args) {
	let password = args?.password;
	let problem = auth.password_problem(password);

	if (problem)
		return invalid_args(`password: ${problem}`);

	let res = auth.hash_password(password, sys.random);

	return res.ok ? { hash: res.data } : { error: res.error, message: Result.describe(res) };
};

/**
 * Runs `command` without blocking rpcd, and replies with the JSON object it
 * prints. io: { popen(command) -> a handle, or null; watch(handle, cb): calls
 * cb once the handle can be read }. The reply is { error: STATUS_FAILED,
 * message } when the command cannot start or prints no object; `name` names
 * it there (the command itself without one).
 *
 * @param {RpcRequest} req the request.
 * @param {RpcIo} io how it runs the command.
 * @param {string} command the shell command.
 * @param {?string} name what the reply calls it.
 * @returns {Object} req.defer()'s, or { error: STATUS_FAILED, message }.
 */
export function deferred_json(req, io, command, name) {
	let p = io.popen(command);

	name ??= command;

	if (!p)
		return { error: STATUS_FAILED, message: `cannot run ${name}` };

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
				: { error: STATUS_FAILED, message: `${name} printed no reply` });
		} catch (e) {
		}
	});

	return req.defer();
};

/**
 * A probe for loader.load in rpcd (prometheus_exporter.probe), which
 * rpcd itself must not run: a collector module whose top level never returns
 * would hang rpcd, and every LuCI page with it, and rpcd's own event loop is
 * not one to run another inside. So `helper` (PROBE_HELPER) probes the modules
 * in a process of its own, which prints what probe.probe found as JSON, and
 * rpcd waits for it, a module's LOAD_TIMEOUT at most; and it does so once for
 * each version of a module, by its inode, size and change time in `dir`
 * (loader.DIR): a reload of rpcd forgets them all. fs: { stat, popen }.
 *
 * @param {module:fs} fs what looks and runs: an object of fs's stat and
 *   popen.
 * @param {string} dir the collectors' directory.
 * @param {string} helper the probe's program (PROBE_HELPER).
 * @returns {function(string[]): Object<string, ProbeOutcome>} the probe,
 *   as loader.load takes it.
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

/**
 * The methods rpcd serves. make_sys(opts) gives a fresh sys per call: rpcd
 * outlives any number of commits and package changes; opts.collectors false
 * leaves the collectors unloaded. io as deferred_json's.
 *
 * @param {function(?{ collectors: ?boolean }): RpcSys} make_sys a fresh sys.
 * @param {RpcIo} io how deferred_json runs a command.
 * @returns {Object<string, { args: Object, call: function(RpcRequest): Object }>}
 *   each method's arguments and call, by name, as rpcd takes them.
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
		hash_password: {
			args: { password: '' },
			call: (req) => hash_password(make_sys({ collectors: false }), req.args),
		},
	};
};

/**
 * sys on the real system. Its committed configuration only, as the exporter
 * reads it. opts.collectors false leaves the collectors unloaded; opts.probe
 * is loader.load's (cached_probe's in rpcd). Its scrapes run each collector
 * in a process of its own (scrape.trial).
 *
 * @param {?{ collectors: ?boolean, probe: ?function(string[]): Object<string, ProbeOutcome> }} opts
 *   the options.
 * @returns {RpcSys} the system.
 */
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
		collectors: load ? loader.load(mods.fs, loader.DIR, loader.import_module, (level, msg) => push(skipped, msg), opts?.probe, loader.import_modules) : [],
		skipped,
		env: scrape_env(mods, quiet),
		ubus: deps.ubus_channel(mods.ubus.connect),
		ledger: st ? ledger.parse(st.read(ledger.NAME)) : null,
		random: deps.urandom(mods.fs),
	};

	// In the service's jail, where it can be had (check.trial).
	sys.trial = (chosen, here) => jailed.trial(sys, sys.collectors, chosen, here);

	return sys;
};
