'use strict';

// `service prometheus-exporter check`: the configuration, checked as
// the exporter and the init script read it; every installed collector, with its
// section, options, needs and what the jail gives it; and one scrape, run here,
// outside the jail, with each collector that fails and why, and each that has
// nothing to observe and why (a success: 'dnsmasq is disabled'). With config_only
// (check.uc --config, which start and reload run) it stops after the
// configuration. Only an invalid configuration makes it fail.
//
// sys: { uci: a uci cursor, fs: { stat }, path: the PATH commands are found on,
//        collectors: the loaded ones, skipped: what the loader logged,
//        env: a scrape env (prometheus_exporter.scrape) }

import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import * as scrape from 'prometheus_exporter.scrape';

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

	if (!svc.ok)
		add('fail', `main: ${Result.describe(svc)}`);
	if (!main.ok)
		add('fail', `main: ${Result.describe(main)}`);
	if (!svc.ok || !main.ok)
		return;

	add('ok', `main: ${svc.data.enabled ? '' : 'disabled (option enabled), '}${listen_summary(svc.data)}, ` +
		`exec_timeout ${main.data.exec_timeout}s, ${main.data.compress ? 'gzip when asked' : 'no compression (option compress)'}`);
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

// The lines that describe one collector.
function describe_collector(sys, c, j) {
	let lines = [ `${c.meta.name} (${c.meta.title}): section '${c.id}', ${j.enabled ? 'enabled' : 'disabled'}` ];
	let row = (label, items) => length(items) && push(lines, sprintf('    %-9s%s', label, join(' ', items)));
	let settings = config.settings(sys.uci, c.id, c.meta);

	for (let k in (j.options.ok ? sort(keys(j.options.data)) : []))
		row('option', [ `${k}=${value_of(j.options.data[k])}`, '#', c.meta.options[k].help ]);
	if (settings.ok && settings.data.timeout != null)
		row('timeout', [ `${settings.data.timeout}s`, '#', TIMEOUT_SOURCES[config.timeout_source(sys.uci, c.id, c.meta)] ]);
	row('needs', c.meta.needs);
	row('configs', c.meta.configs ?? []);
	row('paths', j.paths);
	row('makes', j.owned);
	row('commands', map(sort(keys(j.commands)), (k) => `${k}=${j.commands[k] ?? '(not found)'}`));
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

// One scrape of the enabled collectors: each that fails, and why, and each
// that has nothing to observe, and why.
function check_scrape(sys, add) {
	let chosen = filter(sys.collectors, (c) => config.enabled(sys.uci, c.id));
	let session = sys.env.session();
	let runs = map(chosen, (c) => scrape.run_one(sys.env, session, c));

	session.close();

	let failing = filter(runs, (r) => !r.result.ok);
	let idle = filter(runs, (r) => Result.is_none(r.result));

	add(length(failing) ? 'warn' : 'ok',
		`scrape, outside the jail: ${length(runs) - length(failing)} of ${count(length(runs), 'collector')} succeeded` +
		(length(idle) ? `, ${length(idle)} with nothing to observe` : ''));
	for (let r in failing)
		add('warn', `scrape: ${r.name}: ${Result.describe(r.result)}`);
	for (let r in idle)
		add('ok', `scrape: ${r.name} has nothing to observe: ${r.result.none}`);
}

// { ok, report }: ok unless the configuration is invalid.
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

		check_scrape(sys, add);

		push(lines, '', `collectors: ${length(sys.collectors)} installed, ${enabled} enabled`, ...map(described, (l) => '  ' + l));
		push(lines, '', 'jail mounts:', ...map(mounts, (m) => '  ' + m));
	}

	return { ok, report: join('\n', lines) };
};

export const UHTTPD = '/usr/sbin/uhttpd';

// The service's instances that serve /metrics, of all procd lists for it: not
// the watch instance, which runs beside uhttpd while a path is missing.
export function exporters(instances) {
	return filter(instances ?? [], (i) => i?.command?.[0] == UHTTPD);
};

// The addresses of uhttpd's command line, as URLs: what follows each -p (HTTP)
// and -s (HTTPS).
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

// Whether uhttpd's command line has it check basic auth: a config file (-c)
// other than /dev/null.
export function logs_in(command) {
	for (let i = 0; i < length(command) - 1; i++)
		if (command[i] == '-c' && command[i + 1] != '/dev/null')
			return true;

	return false;
};

// What status prints of a running exporter: where it listens, whether a scrape
// logs in (basic auth), whether it is compressed when asked (compress, as
// configured), and how many collectors it serves (the installed and enabled).
export function status(command, collectors, uci) {
	let serving = length(filter(collectors, (c) => config.enabled(uci, c.id)));
	let main = config.main(uci);
	let compress = main.ok ? main.data.compress : config.MAIN_OPTIONS.compress.default;

	return `listening on ${join(', ', listening(command)) || 'nothing'}` +
		(logs_in(command) ? ', basic auth' : '') + (compress ? ', gzip when asked' : '') +
		`, serving ${count(serving, 'collector')}`;
};
