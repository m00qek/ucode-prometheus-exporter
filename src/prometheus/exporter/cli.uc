/**
 * The command line, /usr/bin/prometheus-exporter, of the package ucode-prometheus-exporter-cli.
 *
 * @module prometheus_exporter_cli
 */

'use strict';

import { docopt } from 'docopt';
import * as Result from 'prometheus.exporter.result';
import * as config from 'prometheus.exporter.config';
import * as deadline from 'prometheus.exporter.deadline';
import * as auth from 'prometheus.exporter.auth';
import * as deps from 'prometheus.exporter.deps';
import * as app from 'prometheus.exporter.app';
import * as check from 'prometheus.exporter.check';
import * as conform from 'prometheus.exporter.conform';
import * as runner from 'prometheus.exporter.runner';
import * as probe from 'prometheus.exporter.probe';
import * as jail from 'prometheus.exporter.jail';
import * as jailed from 'prometheus.exporter.jailed';
import { import_path } from 'prometheus.exporter.collection';

/**
 * What run() takes of the system, as its comment says.
 *
 * @typedef {{
 *   out: function(string): void,
 *   err: function(string): void,
 *   clock: () => int[],
 *   create: function(Log, ?string): App,
 *   jailed_scrape: ?function(string): ?{ status: string, body: string, logs: ?string[][] },
 *   check: function(?{ config_only: ?boolean }): { ok: boolean, report: string },
 *   conform: function(string): { ok: boolean, report: string },
 *   read_password: function(): ?string,
 *   random: function(int): ?string
 * }} CliSys
 */

/**
 * The command line's usage, as docopt parses it and -h prints it.
 *
 * @type {string}
 */
export const USAGE = `prometheus-exporter: metrics of OpenWrt for Prometheus.

Usage:
  prometheus-exporter scrape [--dir=<dir>] [<collector>...]
  prometheus-exporter check [--config]
  prometheus-exporter collector list [--dir=<dir>]
  prometheus-exporter collector check <path>
  prometheus-exporter hash-password
  prometheus-exporter -h | --help
  prometheus-exporter --version

Commands:
  scrape            Print a scrape, as /metrics answers it: of every enabled
                    collector, or of those named, in that order. Each runs as
                    the service runs it, in a child process of the scrape,
                    stopped at its budget, within scrape_timeout.
  check             Check the configuration, describe the installed
                    collectors and run a scrape of them, as the init script's
                    check does.
  collector list    List the installed collectors: name, whether enabled, and
                    what each collects.
  collector check   Check a collector module before it is installed: load it,
                    run it on this device as the service would, and say what
                    it wrote and which rule of the collector contract it
                    broke, if any.
  hash-password     Read a password, without echoing it on a terminal, and
                    print the hash auth_password takes.

Options:
  -d <dir>, --dir=<dir>  Load the collectors from <dir>, a directory on
                         ucode's module path, not the installed ones.
  --config               Check the configuration alone, as start and reload do.
  -h, --help             Show this help.
  --version              Show the version.
`;

function urlencode(s) {
	return replace(s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf('%%%02X', ord(c)));
}

/**
 * The parsed arguments, by docopt, which exits itself on -h, --version or bad usage.
 *
 * @param {string[]} argv the arguments.
 * @param {string} version the exporter's version, which --version prints.
 * @returns {Object} the arguments, by docopt's names ('scrape', '--dir', '<collector>').
 */
export function parse(argv, version) {
	return docopt(USAGE, argv, true, `prometheus-exporter ${version}`);
};

function scrape_cmd(args, sys) {
	let query = join('&', map(args['<collector>'] ?? [], (n) => 'collect[]=' + urlencode(n)));
	let res = (args['--dir'] == null && sys.jailed_scrape) ? sys.jailed_scrape(query) : null;

	if (res) {
		for (let l in res.logs ?? [])
			sys.err(l[1] + '\n');
	} else {
		let app = sys.create((level, msg) => sys.err(msg + '\n'), args['--dir']);
		let main = config.main(app.mods.uci.cursor());
		let budget = deadline.budget(main.ok ? main.data.scrape_timeout : config.SCRAPE_TIMEOUT);

		res = app.scrape(query, { deadline: deadline.seconds(sys.clock()) + budget, budget });
	}

	if (substr(res.status, 0, 3) != '200') {
		sys.err(res.body);
		return 1;
	}

	sys.out(res.body);
	return 0;
}

function list_cmd(args, sys) {
	let app = sys.create((level, msg) => sys.err(msg + '\n'), args['--dir']);
	let uci = app.mods.uci.cursor();

	for (let c in app.collectors())
		sys.out(sprintf('%-24s %-8s %s\n', c.meta.name, config.enabled(uci, c.id) ? 'enabled' : 'disabled', c.meta.help));

	return 0;
}

function report_cmd(res, sys) {
	sys.out(res.report + '\n');
	return res.ok ? 0 : 1;
}

function hash_cmd(sys) {
	let password = sys.read_password();
	let problem = auth.password_problem(password);

	if (problem) {
		sys.err(`password: ${problem}\n`);
		return 1;
	}

	let res = auth.hash_password(password, sys.random);

	if (!res.ok) {
		sys.err(Result.describe(res) + '\n');
		return 1;
	}

	sys.out(res.data + '\n');
	return 0;
}

/**
 * The exit status of a command, for args as parse() gives them.
 *
 * @param {Object} args the arguments, as parse() gives them.
 * @param {CliSys} sys the system.
 * @returns {int} the exit status.
 */
export function run(args, sys) {
	if (args.scrape)
		return scrape_cmd(args, sys);
	if (args.check && !args.collector)
		return report_cmd(sys.check({ config_only: args['--config'] }), sys);
	if (args.collector && args.list)
		return list_cmd(args, sys);
	if (args.collector && args.check)
		return report_cmd(sys.conform(args['<path>']), sys);
	if (args['hash-password'])
		return hash_cmd(sys);

	sys.err(USAGE);
	return 1;
};

/**
 * The shell command that reads a password from the terminal, without echo.
 *
 * @type {string}
 */
export const READ_PASSWORD = "IFS= read -rs p && printf '%s' \"$p\"";

/**
 * A password as a line read gives it, without its line end; null for an empty one.
 *
 * @param {?string} line the line read, or null.
 * @returns {?string} the password, or null.
 */
export function password_of(line) {
	let password = (type(line) == 'string') ? rtrim(line, '\r\n') : null;

	return (password == null || password == '') ? null : password;
};

/**
 * A password from the terminal, or else a line of standard input.
 *
 * @param {module:fs} fs what reads: an object of fs's stdin and popen.
 * @param {?function(string): void} prompt what asks for it on the terminal; warn when null.
 * @returns {?string} the password, or null.
 */
export function read_password(fs, prompt) {
	if (fs.stdin.isatty()) {
		prompt ??= warn;
		prompt('Password: ');

		let p = fs.popen(READ_PASSWORD, 'r');
		let line = p?.read('all');

		p?.close();
		prompt('\n');
		return password_of(line);
	}

	return password_of(fs.stdin.read('line'));
};

/**
 * sys on the real system, for run().
 *
 * @returns {CliSys} the system.
 */
export function system() {
	let mods = deps.modules();
	let quiet = () => null;

	return {
		out: print,
		err: warn,
		clock: () => clock(true),
		create: app.create,
		jailed_scrape: function(query) {
			let collectors = app.load(mods, null, quiet);

			return jailed.run({ uci: mods.uci.cursor(), fs: mods.fs, path: jail.PATH }, collectors, [ 'scrape', query ]);
		},
		check: (opts) => check.run(check.system(opts), opts),
		conform: (path) => conform.run({
			fs: mods.fs,
			uci: mods.uci.cursor(),
			env: app.scrape_env(mods, quiet),
			import_path,
			probe: (id, fn) => probe.probe([ id ], () => fn())[id],
			installed: app.load(mods, null, quiet),
			load_timeout: probe.LOAD_TIMEOUT,
		}, path),
		read_password: () => read_password(mods.fs),
		random: deps.urandom(mods.fs),
	};
};
