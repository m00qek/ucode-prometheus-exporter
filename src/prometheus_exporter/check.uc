/**
 * `prometheus-exporter check`, which `service prometheus-exporter check` runs:
 * the configuration, checked as the exporter and the init script read it;
 * every installed collector, with its section, options, needs and what the
 * jail gives it; and one scrape, in the service's own jail where it can be had
 * (prometheus_exporter.jailed), else here, each collector in a process of its
 * own and stopped at its limit, as the service's scrapes run them
 * (scrape.trial), with each collector that fails and why, and each that has
 * nothing to observe and why (a success: 'dnsmasq is disabled'). With
 * config_only (check --config, which start and reload run) it stops after
 * the configuration. Only an invalid configuration makes it fail.
 *
 * It also says what the service's own scrapes found, from the ledger of its
 * running instance (prometheus_exporter.ledger): each collector quarantined,
 * why and when it is tried again, and each the deadline left out lately.
 * Its own scrape runs every enabled collector all the same, quarantined or
 * not: it is there to see what each does.
 *
 * sys: { uci: a uci cursor, fs: { stat, readfile }, path: the PATH commands are found on,
 *        collectors: the loaded ones, skipped: what the loader logged,
 *        env: a scrape env (prometheus_exporter.scrape, app.scrape_env),
 *        trial(chosen, here) -> { jailed, runs }: the run of `chosen` in the
 *        service's jail (prometheus_exporter.jailed), here() where it cannot
 *        be had; without it, here,
 *        ledger: the service's ledger, or null when it has none }
 *
 * @module prometheus_exporter_check
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import * as privileges from 'prometheus_exporter.privileges';
import * as scrape from 'prometheus_exporter.scrape';
import * as ledger from 'prometheus_exporter.ledger';

/**
 * What check takes of the system, as the module's top comment says.
 *
 * @typedef {{
 *   uci: UciCursor,
 *   fs: module:fs,
 *   path: ?string,
 *   collectors: Collector[],
 *   skipped: ?string[],
 *   env: ScrapeEnv,
 *   trial: ?function(Collector[], function(): Run[]): Trial,
 *   ledger: ?Ledger
 * }} CheckSys
 */

const LABELS = { ok: 'ok  ', warn: 'warn', fail: 'FAIL' };

function count(n, noun) {
	return `${n} ${noun}${n == 1 ? '' : 's'}`;
}

// The user is shown; the hash never is.
function listen_summary(o) {
	let where = o.listen_interface == '*' ? 'every address' : `interface ${o.listen_interface}`;
	let tls = (o.cert != '' && o.key != '') ? 'HTTPS' : 'HTTP';
	let login = (o.auth_user != '') ? `, basic auth as user ${sprintf('%J', o.auth_user)}` : '';

	return `${tls} on ${where}, port ${o.listen_port}, keepalive ${o.http_keepalive}s${login}`;
}

// The memory each of the service's processes may take (memory_limit), as the
// init script works it out.
function memory_summary(fs, mb) {
	let m = match(fs.readfile?.('/proc/meminfo') ?? '', /MemTotal:\s+([0-9]+) kB/);
	let limit = config.memory_limit_mb(mb, m ? +m[1] : 0);

	return (mb > 0) ? `memory_limit ${limit} MB` : `memory_limit ${limit} MB (a quarter of the RAM, at most ${config.MEMORY_LIMIT_MAX})`;
}

// The cert and key the init script serves HTTPS with: both, and both there.
// Without them it serves HTTP, which basic auth refuses: then it does not start.
function check_tls(fs, o, add) {
	let login = (o.auth_user != '');

	if ((o.cert == '') != (o.key == '')) {
		add('warn', `main: cert and key go together; with only ${o.cert != '' ? 'cert' : 'key'}, it serves HTTP`);
		return;
	}

	for (let f in (o.cert != '' ? [ o.cert, o.key ] : []))
		if (fs.stat(f)?.type != 'file')
			add(login ? 'fail' : 'warn', login
				? `main: ${f} is missing; basic auth takes HTTPS only, so the service does not start until it is there`
				: `main: ${f} is missing; it serves HTTP until it is there`);
}

function check_main(sys, add) {
	let main = config.main(sys.uci);
	let svc = config.service(sys.uci);

	// Where 0.2.0 kept the hash, which the package's upgrade moves.
	if (sys.uci.get(config.NAME, 'main', 'auth_password') != null)
		add('warn', `main: auth_password is read from /etc/config/${config.AUTH_CONFIG}; the main section's is ignored`);

	if (!svc.ok)
		add('fail', `main: ${Result.describe(svc)}`);
	if (!main.ok)
		add('fail', `main: ${Result.describe(main)}`);
	if (!svc.ok || !main.ok)
		return;

	add('ok', `main: ${svc.data.enabled ? '' : 'disabled (option enabled), '}${listen_summary(svc.data)}, ` +
		`exec_timeout ${main.data.exec_timeout}s, scrape_timeout ${main.data.scrape_timeout}s, collector_budget ${main.data.collector_budget}s, ` +
		`max_samples ${main.data.max_samples}, ${memory_summary(sys.fs, svc.data.memory_limit)}, ` +
		`${main.data.compress ? 'gzip when asked' : 'no compression (option compress)'}`);
	check_tls(sys.fs, svc.data, add);
}

// Every `config collector` section names an installed collector, and every
// installed collector's options are valid.
function check_sections(sys, add) {
	let ids = map(sys.collectors, (c) => c.id);
	let failed = 0;

	sys.uci.foreach(config.NAME, 'collector', function(s) {
		if (s['.anonymous'])
			add('warn', 'an unnamed collector section is ignored: name it after its collector\'s module');
		else if (!(s['.name'] in ids))
			add('warn', `section '${s['.name']}' names no installed collector; it is ignored`);
	});

	for (let c in sys.collectors) {
		let res = config.collector(sys.uci, c.id, c.meta);

		if (!res.ok) {
			add('fail', `collector ${c.meta.name}, section '${c.id}': ${Result.describe(res)}`);
			failed++;
		}
	}

	if (!failed)
		add('ok', `collectors: ${count(length(sys.collectors), 'installed collector')}, their options valid`);
}

function check_config(sys, add) {
	for (let msg in sys.skipped ?? [])
		add('warn', msg);

	check_main(sys, add);
	check_sections(sys, add);
}

function value_of(v) {
	return type(v) == 'string' ? sprintf('%J', v) : `${v}`;
}

// Where the seconds of a collector's programs come from (config.timeout_source).
const TIMEOUT_SOURCES = {
	timeout: "its section's option timeout",
	'meta.timeout': "the collector's own (meta.timeout)",
	exec_timeout: "the main section's exec_timeout",
};

// Where a collector's budget comes from (config.budget_source).
const BUDGET_SOURCES = {
	budget: "its section's option budget",
	collector_budget: "the main section's collector_budget",
	timeout: 'its timeout and a second more',
};

// The lines that describe one collector.
function describe_collector(sys, c, j) {
	let lines = [ `${c.meta.name} (${c.meta.title}): section '${c.id}', ${j.enabled ? 'enabled' : 'disabled'}` ];
	let row = (label, items) => length(items) && push(lines, sprintf('    %-9s%s', label, join(' ', items)));
	let settings = config.settings(sys.uci, c.id, c.meta);

	for (let k in (j.options.ok ? sort(keys(j.options.data)) : []))
		row('option', [ `${k}=${value_of(j.options.data[k])}`, '#', c.meta.options[k].help ]);
	if (settings.ok && settings.data.timeout != null)
		row('timeout', [ `${settings.data.timeout}s`, '#', TIMEOUT_SOURCES[config.timeout_source(sys.uci, c.id, c.meta)] ]);
	if (settings.ok)
		row('budget', [ `${settings.data.budget}s`, '#', BUDGET_SOURCES[config.budget_source(sys.uci, c.id, settings.data.timeout)] ]);
	row('needs', c.meta.needs);
	row('configs', c.meta.configs ?? []);
	row('paths', j.paths);
	row('makes', j.owned);
	row('commands', map(sort(keys(j.commands)), (k) => `${k}=${j.commands[k] ?? '(not found)'}`));
	row('ubus', map(keys(j.ubus), (o) => `${o}:${join(',', j.ubus[o])}`));
	row('caps', j.capabilities);
	row('groups', j.groups);
	row('reads', j.proc_files);
	if (j.enabled)
		row('mounts', j.mounts);

	return lines;
}

function describe_collectors(sys, add_line, add) {
	let enabled = 0;

	for (let c in sys.collectors) {
		let j = jail.collector(c, sys);

		if (j.enabled)
			enabled++;
		for (let p in j.problems)
			add('warn', `jail: ${c.meta.name}: ${p}`);
		for (let p in (j.enabled ? j.missing : []))
			add('warn', `jail: ${c.meta.name}: ${p} is not there; the service mounts it once it is`);
		for (let l in describe_collector(sys, c, j))
			add_line(l);
	}

	return enabled;
}

/**
 * A run of each of `chosen`: sys.trial's, in the service's jail where it can
 * be had ({ jailed, runs }), or else here, guarded as the service's are
 * (scrape.trial).
 *
 * @param {CheckSys} sys the system.
 * @param {Collector[]} chosen the collectors to run.
 * @returns {Trial} the runs.
 */
export function trial(sys, chosen) {
	let here = () => scrape.trial(sys.env, sys.uci, sys.ledger, chosen, sys.collectors);

	return sys.trial ? sys.trial(chosen, here) : { jailed: false, runs: here() };
};

// One scrape of the enabled collectors: each that fails, and why, and each
// that has nothing to observe, and why.
function check_scrape(sys, add) {
	let chosen = filter(sys.collectors, (c) => config.enabled(sys.uci, c.id));
	let t = trial(sys, chosen);
	let runs = t.runs;

	let failing = filter(runs, (r) => !r.result.ok);
	let idle = filter(runs, (r) => Result.is_none(r.result));

	add(length(failing) ? 'warn' : 'ok',
		`scrape, ${t.jailed ? 'in the service\'s jail' : 'outside the jail'}: ${length(runs) - length(failing)} of ${count(length(runs), 'collector')} succeeded` +
		(length(idle) ? `, ${length(idle)} with nothing to observe` : ''));
	for (let r in failing)
		add('warn', `scrape: ${r.name}: ${Result.describe(r.result)}`);
	for (let r in idle)
		add('ok', `scrape: ${r.name} has nothing to observe: ${r.result.none}`);
}

// What the service's scrapes found of each collector, by its ledger: the ones
// quarantined, and the ones the deadline left out in its last RECENT scrapes.
function check_service(sys, add) {
	if (sys.ledger == null)
		return;

	for (let c in sys.collectors) {
		let r = ledger.report(sys.ledger, c.id);

		if (r?.quarantined)
			add('warn', `service: ${c.meta.name} is quarantined: ${r.reason}; the service tries it again ` +
				((r.retry_in <= 1) ? 'at the next scrape' : `in ${r.retry_in} scrapes`) + ', or at once once restarted');
		if (r?.late != null && r.late < ledger.RECENT)
			add('warn', `service: the scrape deadline left ${c.meta.name} out ` +
				((r.late == 0) ? 'in the last scrape' : `${r.late} scrape${r.late == 1 ? '' : 's'} ago`));
	}
}

/**
 * { ok, report }: ok unless the configuration is invalid.
 *
 * @param {CheckSys} sys the system.
 * @param {?{ config_only: ?boolean }} opts config_only: check --config.
 * @returns {{ ok: boolean, report: string }} whether the configuration is
 *   valid, and the report, a line each.
 */
export function run(sys, opts) {
	let lines = [];
	let ok = true;
	let add = function(level, text) {
		if (level == 'fail')
			ok = false;
		push(lines, `${LABELS[level]} ${text}`);
	};

	check_config(sys, add);

	if (!opts?.config_only) {
		let described = [];
		let enabled = describe_collectors(sys, (l) => push(described, l), add);
		let mounts = jail.mounts(sys.collectors, sys).mounts;
		let g = jail.grants(sys.collectors, sys);

		check_scrape(sys, add);
		check_service(sys, add);

		push(lines, '', `collectors: ${length(sys.collectors)} installed, ${enabled} enabled`, ...map(described, (l) => '  ' + l));
		push(lines, '', 'jail mounts:', ...map(mounts, (m) => '  ' + m));
		push(lines, '', `jail user: ${privileges.USER}, capabilities: ${join(' ', privileges.service_capabilities(g)) || 'none'}`,
			'ubus ACL:', ...map(keys(g.ubus), (o) => `  ${o} ${join(' ', g.ubus[o])}`));
	}

	return { ok, report: join('\n', lines) };
};

/**
 * uhttpd, the program a serving instance runs.
 *
 * @type {string}
 */
export const UHTTPD = '/usr/sbin/uhttpd';

/**
 * The service's instances that serve /metrics, of all procd lists for it: not
 * the watch instance, which runs beside uhttpd while a path is missing.
 *
 * @param {?Object[]} instances procd's instances of the service.
 * @returns {Object[]} those whose command runs UHTTPD.
 */
export function exporters(instances) {
	return filter(instances ?? [], (i) => i?.command?.[0] == UHTTPD);
};

/**
 * The addresses of uhttpd's command line, as URLs: what follows each -p (HTTP)
 * and -s (HTTPS).
 *
 * @param {string[]} command uhttpd's command line.
 * @returns {string[]} the URLs of /metrics.
 */
export function listening(command) {
	let urls = [];

	for (let i = 0; i < length(command) - 1; i++) {
		let scheme = { '-p': 'http', '-s': 'https' }[command[i]];
		let addr = command[i + 1];

		if (scheme)
			push(urls, `${scheme}://${match(addr, /^[0-9]+$/) ? '*:' + addr : addr}/metrics`);
	}

	return urls;
};

/**
 * Whether uhttpd's command line has it check basic auth: a config file (-c)
 * other than /dev/null.
 *
 * @param {string[]} command uhttpd's command line.
 * @returns {boolean} whether it does.
 */
export function logs_in(command) {
	for (let i = 0; i < length(command) - 1; i++)
		if (command[i] == '-c' && command[i + 1] != '/dev/null')
			return true;

	return false;
};

/**
 * What status prints of a running exporter: where it listens, whether a scrape
 * logs in (basic auth), whether it is compressed when asked (compress, as
 * configured), and how many collectors it serves (the installed and enabled).
 *
 * @param {string[]} command uhttpd's command line.
 * @param {Collector[]} collectors the installed collectors.
 * @param {UciCursor} uci the cursor.
 * @returns {string} the line.
 */
export function status(command, collectors, uci) {
	let serving = length(filter(collectors, (c) => config.enabled(uci, c.id)));
	let main = config.main(uci);
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;

	return `listening on ${join(', ', listening(command)) || 'nothing'}` +
		(logs_in(command) ? ', basic auth' : '') + (compress ? ', gzip when asked' : '') +
		`, serving ${count(serving, 'collector')}`;
};
