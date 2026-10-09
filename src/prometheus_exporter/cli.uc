/**
 * The command line, /usr/bin/prometheus-exporter, of the package
 * ucode-prometheus-exporter-cli. USAGE is its interface: docopt (the
 * ucode-docopt package, which only this package depends on) parses the
 * arguments by it, and the reference page is written from it (make
 * docs-gen). Only the command line loads docopt: neither the handler, nor
 * rpcd, nor the init script ever does; the init script's check is the base
 * package's (prometheus_exporter.check's system()), which this command's
 * check runs too.
 *
 * @module prometheus_exporter_cli
 */

'use strict';

import { docopt } from 'docopt';
import * as Result from 'prometheus_exporter.result';
import * as config from 'prometheus_exporter.config';
import * as deadline from 'prometheus_exporter.deadline';
import * as auth from 'prometheus_exporter.auth';
import * as deps from 'prometheus_exporter.deps';
import * as app from 'prometheus_exporter.app';
import * as check from 'prometheus_exporter.check';
import * as conform from 'prometheus_exporter.conform';
import * as runner from 'prometheus_exporter.runner';
import * as probe from 'prometheus_exporter.probe';
import * as jail from 'prometheus_exporter.jail';
import * as jailed from 'prometheus_exporter.jailed';
import { import_path } from 'prometheus_exporter.collection';

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
                    the service runs it, in a process of its own, stopped at
                    its budget, within scrape_timeout.
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
 * The parsed arguments, by docopt: it prints the help or the version, or the
 * usage on standard error for arguments it does not take, and exits itself.
 *
 * @param {string[]} argv the arguments.
 * @param {string} version the exporter's version, which --version prints.
 * @returns {Object} the arguments, by docopt's names: commands and options
 *   as keys ('scrape', '--dir', '<collector>').
 */
export function parse(argv, version) {
	return docopt(USAGE, argv, true, `prometheus-exporter ${version}`);
};

// A scrape on standard output, of the named collectors, within the
// configuration's scrape_timeout: in the service's jail, where it can be had
// (sys.jailed_scrape), else here. --dir's collectors are a source tree's,
// which the jail has not.
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
 * The exit status of a command, for args as parse() gives them. sys: {
 *   out(text), err(text), clock(),
 *   create(log, dir): prometheus_exporter.app's create,
 *   jailed_scrape(query) -> { status, body, logs }, the scrape in the
 *     service's jail, or null where it cannot be had (optional),
 *   check({ config_only }) -> check.run's { ok, report },
 *   conform(path) -> conform.run's { ok, report },
 *   read_password() -> the password read, or null,
 *   random(n): n random bytes }
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
 * The shell command that reads a password from the terminal: `read -s` of
 * the shell keeps it from echoing (OpenWrt has no stty), and an empty IFS
 * keeps the spaces it starts or ends with, which are the password's.
 *
 * @type {string}
 */
export const READ_PASSWORD = "IFS= read -rs p && printf '%s' \"$p\"";

/**
 * A password as a line read gives it: the line less the CRs and LFs that
 * end it, and nothing else; null for an empty one.
 *
 * @param {?string} line the line read, or null.
 * @returns {?string} the password, or null.
 */
export function password_of(line) {
	let password = (type(line) == 'string') ? rtrim(line, '\r\n') : null;

	return (password == null || password == '') ? null : password;
};

/**
 * A password from the terminal (READ_PASSWORD), or else a line of standard
 * input, either as password_of gives it. Never on a command line, where ps
 * would show it.
 *
 * @param {module:fs} fs what reads: an object of fs's stdin and popen.
 * @param {?function(string): void} prompt what asks for it on the terminal;
 *   warn, to standard error, when null.
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
		check: (opts) => check.run(check.system(), opts),
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
