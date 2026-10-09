/**
 * Options from /etc/config/prometheus-exporter. Each is declared as
 * { default, title, help, datatype, secret }: the default sets its type (a
 * boolean takes uci's boolean spellings, an integer an integer, a string any
 * single value), the title labels it in a form (a collector's options and the
 * core's options of a collector have one), help is a sentence saying what it
 * does, and the optional datatype, one of LuCI's names (and `regex`,
 * `username` and `crypt`), narrows the values it takes as LuCI would
 * (prometheus_exporter.config.types). A secret option's value is never part
 * of a message. Unset options take the default; options nobody declared are
 * ignored, so an older config never breaks a scrape.
 *
 * It is the facade of config/: what others take of the modules there it
 * exports, under the names below.
 *
 * @module prometheus_exporter_config
 */

'use strict';

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as types from 'prometheus_exporter.config.types';
import * as problems from 'prometheus_exporter.config.problems';

/**
 * An option as it is declared: its default, which sets its type (a boolean,
 * an integer or a string; absent from the core's TIMEOUT, BUDGET and
 * SAMPLES, whose defaults are worked out), its title, the sentence of its
 * help, its datatype, and whether its value is a secret. A collector's
 * options and the core's options of a collector have a title, the label a
 * form shows them by; the main section's have none, as LuCI labels them.
 *
 * @typedef {{ default: ?(boolean|int|string), title: ?string, help: string, datatype: ?string, secret: ?boolean }} OptionSpec
 */

/**
 * Every setting of a collector, as settings() gives them: the core's, and
 * its own options, typed, as collect() gets them. timeout is null for a
 * collector that runs no programs.
 *
 * @typedef {{ enabled: boolean, timeout: ?int, budget: int, max_samples: int, options: Object }} Settings
 */

/**
 * The main section's options the exporter reads (MAIN_OPTIONS), typed.
 *
 * @typedef {{
 *   omit_zero_values: boolean,
 *   compress: boolean,
 *   exec_timeout: int,
 *   scrape_timeout: int,
 *   collector_budget: int,
 *   max_samples: int,
 *   max_scrape_samples: int
 * }} MainSettings
 */

/**
 * The main section's options the init script reads (SERVICE_OPTIONS), typed.
 *
 * @typedef {{
 *   enabled: boolean,
 *   listen_interface: string,
 *   listen_port: int,
 *   http_keepalive: int,
 *   cert: string,
 *   key: string,
 *   auth_user: string,
 *   auth_password: string,
 *   memory_limit: int
 * }} ServiceSettings
 */

// uci's spellings of a boolean, the datatypes the core enforces, and a uci
// value as an option takes it.
export const TRUE = types.TRUE;
export const FALSE = types.FALSE;
export const DATATYPES = types.DATATYPES;
export const datatype = types.datatype;
export const convert = types.convert;

// Where the service makes and mounts a directory of a collector's own, and
// whether a path is one (config.types).
export const OWNED_ROOTS = types.OWNED_ROOTS;
export const is_owned_directory = types.is_owned_directory;

// What is wrong with an option's value, as a code and its arguments
// (prometheus_exporter.config.problems): every code, with what it takes and
// says; a problem of one; its English; and the CONFIG_INVALID of a value an
// option does not take, which holds it.
export const PROBLEMS = problems.CODES;
export const problem = problems.problem;
export const english = problems.english;
export const invalid = types.invalid;

/**
 * The service's name: its uci config (and the main section's type), its init
 * script, its command, its libexec directory and its ubus object.
 *
 * @type {string}
 */
export const NAME = 'prometheus-exporter';

/**
 * The apk package of the exporter; each collector package is PACKAGE-<name>.
 *
 * @type {string}
 */
export const PACKAGE = 'ucode-prometheus-exporter';

/**
 * The seconds the programs a collector runs (exec) get in all in each scrape,
 * unless it says otherwise. Prometheus gives a scrape 10 s by default
 * (scrape_timeout): a collector whose program hangs for all of its 5 s still
 * leaves the rest of the scrape, well under a second, time to answer. The
 * programs collectors run answer in milliseconds (nft, ethtool, mmcli over
 * D-Bus) or in a second or so (an ssh login to a radio).
 *
 * @type {int}
 */
export const EXEC_TIMEOUT = 5;

/**
 * The seconds uhttpd gives the handler to answer a request (its -t, which
 * the init script sets), after which it kills the request, answering nothing.
 *
 * @type {int}
 */
export const SCRIPT_TIMEOUT = 60;

/**
 * The most seconds they may get: half of what uhttpd gives a scrape.
 *
 * @type {int}
 */
export const EXEC_TIMEOUT_MAX = SCRIPT_TIMEOUT / 2;

const EXEC_TIMEOUT_RANGE = `range(1,${EXEC_TIMEOUT_MAX})`;

/**
 * The seconds a scrape has when the scraper does not say
 * (X-Prometheus-Scrape-Timeout-Seconds, which Prometheus and vmagent send):
 * Prometheus's own default scrape_timeout, and vmagent's.
 *
 * @type {int}
 */
export const SCRAPE_TIMEOUT = 10;

/**
 * The seconds a collector may take in a scrape before its breaker trips
 * (prometheus_exporter.breaker), unless it says otherwise: half of
 * Prometheus's default timeout. Every collector takes a small part of it on
 * a router: a typical full scrape takes a 500-MIPS MIPS router 2 seconds in
 * all; only nat_traffic on a table of tens of thousands goes past it.
 *
 * @type {int}
 */
export const COLLECTOR_BUDGET = 5;

const SECONDS_RANGE = `range(1,${SCRIPT_TIMEOUT})`;

/**
 * The samples a collector may write in a scrape, unless it says otherwise
 * (meta.max_samples, or its section's max_samples): one that writes more fails
 * with SAMPLE_LIMIT, and the scrape keeps none of them. The most any collector
 * writes on the benchmark's large world, a router busier than most, is 3,650
 * (snmp6 on 50 devices; ethtool writes 1,980 on 17 ports, wifi 2,502 for 100
 * stations), and some 0.5 kB of memory each while a scrape holds them: 20,000
 * leaves five times that, and bounds what a runaway holds to some 10 MB.
 * nat_traffic, whose samples are the connection table's address pairs, says
 * more.
 *
 * @type {int}
 */
export const MAX_SAMPLES = 20000;

/**
 * The most max_samples may be: some 50 MB of samples in one scrape.
 *
 * @type {int}
 */
export const MAX_SAMPLES_MAX = 100000;

const SAMPLES_RANGE = `range(1,${MAX_SAMPLES_MAX})`;

/**
 * The samples the collectors of one reply may write in all: a collector whose
 * samples would go past it fails with SAMPLE_LIMIT, and one started once it is
 * reached is not run. The benchmark's large world, a router busier than most,
 * writes 33,600; the scrape process holds some 0.2 kB of each, its text and
 * the reply's, so 200,000 is some 40 MB, under the memory limit's 64 MB at
 * most, where a reply without one could run the scrape out of memory and have
 * the next blame the collector that happened to be running.
 *
 * @type {int}
 */
export const MAX_SCRAPE_SAMPLES = 200000;

/**
 * The most max_scrape_samples may be.
 *
 * @type {int}
 */
export const MAX_SCRAPE_SAMPLES_MAX = 1000000;

/**
 * The main section's options the exporter itself reads; the others are the
 * init script's (SERVICE_OPTIONS).
 *
 * @type {Object<string, OptionSpec>}
 */
export const MAIN_OPTIONS = {
	omit_zero_values: { default: false, help: 'Leave out counters that are 0, most of which never move on a router.' },
	compress: { default: true, help: 'Send a scrape gzip-compressed when the scraper asks for it (Accept-Encoding: gzip); 0 never does.' },
	exec_timeout: {
		default: EXEC_TIMEOUT, datatype: EXEC_TIMEOUT_RANGE,
		help: 'Seconds the programs a collector runs get in all in each scrape, unless the collector says otherwise; one still running then is killed.',
	},
	scrape_timeout: {
		default: SCRAPE_TIMEOUT, datatype: SECONDS_RANGE,
		help: 'Seconds a scrape has to answer when the scraper does not say (X-Prometheus-Scrape-Timeout-Seconds); collectors left when they are nearly spent are skipped.',
	},
	collector_budget: {
		default: COLLECTOR_BUDGET, datatype: SECONDS_RANGE,
		help: 'Seconds a collector may take in a scrape, unless it says otherwise; one still running then is stopped, and quarantined for a few scrapes.',
	},
	max_samples: {
		default: MAX_SAMPLES, datatype: SAMPLES_RANGE,
		help: 'Samples a collector may write in a scrape, unless it says otherwise; one that writes more fails, and none of its samples are served.',
	},
	max_scrape_samples: {
		default: MAX_SCRAPE_SAMPLES, datatype: `range(1,${MAX_SCRAPE_SAMPLES_MAX})`, title: 'Reply sample limit',
		help: 'Samples the collectors of a scrape may write in all; a collector whose samples would go past it fails, and none of its samples are served.',
	},
};

/**
 * What every collector has besides its own options: the core's.
 *
 * @type {OptionSpec}
 */
export const ENABLED = { default: true, title: 'Enabled', help: 'Serve this collector; 0 leaves it out, and naming it in a query is a 400.' };

/**
 * The core's option of a collector that runs programs (exec in meta.needs),
 * without its default, which is the collector's meta.timeout or else the main
 * section's exec_timeout (default_timeout).
 *
 * @type {OptionSpec}
 */
export const TIMEOUT = {
	title: 'Program timeout',
	datatype: EXEC_TIMEOUT_RANGE,
	help: 'Seconds the programs of this collector get in all in each scrape; one still running then is killed.',
};

/**
 * The core's option of every collector, without its default, which is the
 * main section's collector_budget, or for a collector that runs programs its
 * timeout and a second more when that is longer (default_budget).
 *
 * @type {OptionSpec}
 */
export const BUDGET = {
	title: 'Budget',
	datatype: SECONDS_RANGE,
	help: 'Seconds this collector may take in a scrape; one still running then is stopped, and quarantined for a few scrapes.',
};

/**
 * The core's option of every collector, without its default, which is its
 * meta.max_samples or else the main section's max_samples
 * (default_max_samples).
 *
 * @type {OptionSpec}
 */
export const SAMPLES = {
	title: 'Sample limit',
	datatype: SAMPLES_RANGE,
	help: 'Samples this collector may write in a scrape; one that writes more fails, and none of its samples are served.',
};

/**
 * The option names the core keeps for itself: no collector declares them.
 * `timeout` is only an exec collector's; the others ignore it.
 *
 * @type {string[]}
 */
export const RESERVED = [ 'enabled', 'timeout', 'budget', 'max_samples' ];

/**
 * The core's options of a collector with this meta, by name: enabled;
 * timeout, whose default is `seconds`, when it runs programs; budget, whose
 * default is `budget` (COLLECTOR_BUDGET without one); and max_samples, whose
 * default is `samples` (MAX_SAMPLES without one).
 *
 * @param {?Meta} meta the collector's meta.
 * @param {?int} seconds the default of timeout.
 * @param {?int} budget the default of budget.
 * @param {?int} samples the default of max_samples.
 * @returns {Object<string, OptionSpec>} enabled, timeout when it runs
 *   programs, budget and max_samples.
 */
export function core(meta, seconds, budget, samples) {
	let out = { enabled: ENABLED };

	if ('exec' in (meta?.needs ?? []))
		out.timeout = { default: seconds, ...TIMEOUT };

	out.budget = { default: budget ?? COLLECTOR_BUDGET, ...BUDGET };
	out.max_samples = { default: samples ?? MAX_SAMPLES, ...SAMPLES };

	return out;
};

/**
 * The defaults of options declared as { default, ... }.
 *
 * @param {Object<string, OptionSpec>} specs the options.
 * @returns {Object} each option's default, by name.
 */
export function defaults(specs) {
	let out = {};

	for (let key, spec in specs)
		out[key] = spec.default;

	return out;
};

/**
 * The options of section `name`, of section type `stype`, as `specs` declare
 * them, in the exporter's config, or in config `pkg`.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} name the section's name.
 * @param {string} stype the type the section must be of; any other reads
 *   as unset.
 * @param {Object<string, OptionSpec>} specs the options.
 * @param {?string} pkg the config; NAME when null.
 * @returns {Result<Object>} each option's value, typed, by name, or the first
 *   invalid one's CONFIG_INVALID.
 */
export function section(uci, name, stype, specs, pkg) {
	let s = uci.get_all(pkg ?? NAME, name);
	let options = {};

	if (type(s) != 'object' || s['.type'] != stype)
		s = {};

	for (let key, spec in specs) {
		if (!(key in s)) {
			options[key] = spec.default;
			continue;
		}

		let res = convert(key, s[key], spec);
		if (!res.ok)
			return res;
		options[key] = res.data;
	}

	return Result.ok(options);
};

/**
 * The main section's options the exporter reads (MAIN_OPTIONS).
 *
 * @param {UciCursor} uci the cursor.
 * @returns {Result<MainSettings>} them, or CONFIG_INVALID.
 */
export function main(uci) {
	return section(uci, 'main', NAME, MAIN_OPTIONS);
};

/**
 * The least memory_limit but 0, in MB: under it uhttpd cannot load the
 * handler, and so crash-loops, though the configuration is valid. The least
 * under which uhttpd loads the handler and a typical scrape of every
 * collector succeeds (make bench's floor: cases) is 7 MB on x86_64 and on a
 * Cortex-A53, 5 MB on a 32-bit MIPS 24Kc (QEMU), and for the base package's
 * collectors 4 and 3 MB: 8 holds on each, with room for a collector or two of
 * another package, and past that a collector that takes more fails alone.
 *
 * @type {int}
 */
export const MEMORY_LIMIT_MIN = 8;

/**
 * The main section's options the init script reads, with its defaults: whether
 * the service runs, where uhttpd listens, its TLS files ('' for none), the
 * user of basic auth ('' for none) and the memory limit. The hash of basic
 * auth's password is in a config of its own (AUTH_CONFIG).
 *
 * @type {Object<string, OptionSpec>}
 */
export const SERVICE_OPTIONS = {
	enabled: { default: true, help: 'Run the service; 0 stops it.' },
	listen_interface: { default: 'loopback', help: 'The logical interface uhttpd listens on, or * for every address.' },
	listen_port: { default: 9100, datatype: 'range(1,65535)', help: 'The port uhttpd listens on.' },
	http_keepalive: { default: 70, datatype: 'uinteger', help: 'Seconds an idle connection is kept open; 0 for none.' },
	cert: { default: '', help: 'The certificate to serve HTTPS with, along with key.' },
	key: { default: '', help: 'The private key of cert.' },
	auth_user: { default: '', datatype: 'username', help: 'The user a scrape logs in as (basic auth), with auth_password; HTTPS only.' },
	memory_limit: {
		default: 0, datatype: `zero_or_min(${MEMORY_LIMIT_MIN})`,
		help: `MB of memory each of the exporter's processes may take (its data, RLIMIT_DATA), ${MEMORY_LIMIT_MIN} or more: a collector that takes more fails alone. 0 for a quarter of the RAM, at most 64 MB.`,
	},
};

/**
 * The config of basic auth's hash, apart from the exporter's own: LuCI's
 * read ACL grants the exporter's config, and the hash is none of what a login
 * that reads the settings may read. The ubus object's set_password writes it,
 * and the init script reads it, both as root; the jail does not mount it.
 * The package installs it, mode 0600, with its one section.
 *
 * @type {string}
 */
export const AUTH_CONFIG = `${NAME}-auth`;

/**
 * Its section: `config auth 'main'`.
 *
 * @type {string}
 */
export const AUTH_SECTION = 'main';

/**
 * The type of its section.
 *
 * @type {string}
 */
export const AUTH_TYPE = 'auth';

/**
 * The options of AUTH_CONFIG's section, which the init script reads with
 * SERVICE_OPTIONS: the hash of basic auth's password ('' for none).
 *
 * @type {Object<string, OptionSpec>}
 */
export const AUTH_OPTIONS = {
	auth_password: {
		default: '', datatype: 'crypt', secret: true,
		help: 'The crypt hash of the password of auth_user: $1$ (uhttpd -m), $5$ or $6$, as the ubus object\'s hash_password makes it.',
	},
};

/**
 * The hash of basic auth's password as AUTH_CONFIG holds it, checked.
 *
 * @param {UciCursor} uci the cursor.
 * @returns {Result<{ auth_password: string }>} it, '' for none; or
 *   CONFIG_INVALID, which never holds it.
 */
export function auth_values(uci) {
	return section(uci, AUTH_SECTION, AUTH_TYPE, AUTH_OPTIONS, AUTH_CONFIG);
};

/**
 * memory_limit when it is 0: a quarter of the RAM, at most MEMORY_LIMIT_MAX MB,
 * which the init script works out (memory_limit_mb()). Measured as the peak
 * resident memory of a scrape's child process (make bench): a typical
 * router's full scrape 9 MB on a 64-bit CPU and 7 MB on a 32-bit MIPS one
 * (QEMU), the benchmark's large world, a router busier than most, with every
 * collector, 30 MB on 64 bits and 22 MB on the MIPS one. 64 MB leaves more than twice the largest, and
 * a router with less RAM than 256 MB a quarter of what it has.
 *
 * @type {int}
 */
export const MEMORY_LIMIT_MAX = 64;

/**
 * The share of the RAM memory_limit 0 takes: a quarter (see
 * MEMORY_LIMIT_MAX).
 *
 * @type {int}
 */
export const MEMORY_LIMIT_SHARE = 4;

/**
 * The MB memory_limit `mb` makes on a device of `total_kb` kB of RAM.
 *
 * @param {int} mb memory_limit.
 * @param {int} total_kb the device's RAM, in kB.
 * @returns {int} the limit, in MB.
 */
export function memory_limit_mb(mb, total_kb) {
	return (mb > 0) ? mb : min(MEMORY_LIMIT_MAX, int(total_kb / 1024 / MEMORY_LIMIT_SHARE));
};

/**
 * The init script's options, each alone: what it would misread. The hash
 * (AUTH_OPTIONS) is AUTH_CONFIG's, read while the main section sets
 * auth_user, '' otherwise.
 *
 * @param {UciCursor} uci the cursor.
 * @returns {Result<ServiceSettings>} them, or CONFIG_INVALID.
 */
export function service_values(uci) {
	let res = section(uci, 'main', NAME, SERVICE_OPTIONS);

	if (res.ok && res.data.listen_interface == '')
		return invalid('listen_interface', problems.problem(problems.INTERFACE), '');
	if (!res.ok)
		return res;

	// The hash is read only for a user: without one it is no basic auth.
	let hash = (res.data.auth_user != '') ? auth_values(uci) : Result.ok(defaults(AUTH_OPTIONS));

	return hash.ok ? Result.ok({ ...res.data, ...hash.data }) : hash;
};

/**
 * What is wrong of the init script's options that go together (`options`, typed),
 * by option: basic auth's user, which turns it on, needs the hash of a
 * password, and cert and key, as Basic sends the password in the clear. A
 * hash without a user is no basic auth: it is kept apart (AUTH_CONFIG), and
 * saved before the user it goes with is applied.
 *
 * @param {ServiceSettings} options the init script's options, typed.
 * @returns {Object<string, Problem>} what is wrong, by option: problems of
 *   AUTH_NEEDS_PASSWORD and AUTH_NEEDS_TLS; {} when nothing is.
 */
export function together(options) {
	let out = {};
	let user = (options.auth_user ?? '') != '', hash = (options.auth_password ?? '') != '';

	if (user && !hash)
		out.auth_password = problems.problem(problems.AUTH_NEEDS_PASSWORD);

	if (user && ((options.cert ?? '') == '' || (options.key ?? '') == ''))
		out.auth_user ??= problems.problem(problems.AUTH_NEEDS_TLS);

	return out;
};

/**
 * The init script's options, checked so that start refuses what it would
 * misread, or serve without what it is told to (basic auth over HTTP).
 *
 * @param {UciCursor} uci the cursor.
 * @returns {Result<ServiceSettings>} them, or CONFIG_INVALID.
 */
export function service(uci) {
	let res = service_values(uci);

	if (!res.ok)
		return res;

	for (let name, p in together(res.data))
		return Result.err(errors.CONFIG_INVALID, problems.message(name, p), { option: name, problem: p });

	return res;
};

/**
 * Basic auth as the main section's auth_user and AUTH_CONFIG's hash set it: a
 * Result of { user, hash }, or of null when the main section sets no user; an error when the init script's options are not valid.
 *
 * @param {UciCursor} uci the cursor.
 * @returns {Result<?BasicAuth>} basic auth, or null for none; or
 *   CONFIG_INVALID.
 */
export function auth(uci) {
	let res = service(uci);

	if (!res.ok)
		return res;

	return Result.ok(res.data.auth_user != '' ? { user: res.data.auth_user, hash: res.data.auth_password } : null);
};

/**
 * The seconds a collector's programs get when its section sets no timeout:
 * its meta.timeout, or else the main section's exec_timeout (its default while
 * the main section is not valid, which check and the init script refuse).
 *
 * @param {UciCursor} uci the cursor.
 * @param {?Meta} meta the collector's meta.
 * @param {?Result<MainSettings>} main_res main(uci), when read already.
 * @returns {int} the seconds.
 */
export function default_timeout(uci, meta, main_res) {
	if (meta?.timeout != null)
		return meta.timeout;

	let res = main_res ?? main(uci);

	return res.ok ? res.data.exec_timeout : EXEC_TIMEOUT;
};

/**
 * The seconds a collector may take when its section sets no budget: the main
 * section's collector_budget (its default while the main section is not
 * valid); for a collector whose programs get `timeout` seconds, that and a
 * second more when it is longer, as the watchdog counts whole seconds: a
 * budget never quarantines what a timeout allows.
 *
 * @param {UciCursor} uci the cursor.
 * @param {?int} timeout the seconds of its programs, or null for a collector
 *   that runs none.
 * @param {?Result<MainSettings>} main_res main(uci), when read already.
 * @returns {int} the seconds.
 */
export function default_budget(uci, timeout, main_res) {
	let res = main_res ?? main(uci);
	let budget = res.ok ? res.data.collector_budget : COLLECTOR_BUDGET;

	return (timeout != null) ? max(budget, timeout + 1) : budget;
};

/**
 * The samples a collector may write when its section sets no max_samples:
 * its meta.max_samples, or else the main section's max_samples (its default
 * while the main section is not valid).
 *
 * @param {UciCursor} uci the cursor.
 * @param {?Meta} meta the collector's meta.
 * @param {?Result<MainSettings>} main_res main(uci), when read already.
 * @returns {int} the samples.
 */
export function default_max_samples(uci, meta, main_res) {
	if (meta?.max_samples != null)
		return meta.max_samples;

	let res = main_res ?? main(uci);

	return res.ok ? res.data.max_samples : MAX_SAMPLES;
};

/**
 * Where a collector's budget comes from: its section's `budget`, the main
 * section's `collector_budget`, or its `timeout`.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} id the collector's module name, its section's name.
 * @param {?int} timeout the seconds of its programs, or null.
 * @returns {string} 'budget', 'collector_budget' or 'timeout'.
 */
export function budget_source(uci, id, timeout) {
	let s = uci.get_all(NAME, id);

	if (type(s) == 'object' && s['.type'] == 'collector' && 'budget' in s)
		return 'budget';

	let res = main(uci);
	let budget = res.ok ? res.data.collector_budget : COLLECTOR_BUDGET;

	return (timeout != null && timeout + 1 > budget) ? 'timeout' : 'collector_budget';
};

/**
 * Where a collector's seconds come from: its section's `timeout`, its
 * `meta.timeout` or the main section's `exec_timeout`; null for a collector
 * that runs no programs.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} id the collector's module name, its section's name.
 * @param {?Meta} meta the collector's meta.
 * @returns {?string} 'timeout', 'meta.timeout' or 'exec_timeout', or null.
 */
export function timeout_source(uci, id, meta) {
	if (!('exec' in (meta?.needs ?? [])))
		return null;

	let s = uci.get_all(NAME, id);

	if (type(s) == 'object' && s['.type'] == 'collector' && 'timeout' in s)
		return 'timeout';

	return (meta.timeout != null) ? 'meta.timeout' : 'exec_timeout';
};

/**
 * `config collector '<id>'`: the collector's module name, as a uci section name
 * cannot hold the '-' of ltq-dsl.
 *
 * Every setting of the collector with this meta, as a Result of { enabled,
 * timeout, budget, max_samples, options }: the core's options (enabled;
 * timeout when it runs programs, null otherwise; budget; max_samples) are
 * checked like its own, which `options` holds. So timeout's precedence: the
 * section's, then meta.timeout, then the main section's exec_timeout;
 * budget's: the section's, then default_budget's; max_samples': the
 * section's, then meta.max_samples, then the main section's. `main_res`, the
 * main section's as main(uci) reads it, is read here when not given: a scrape
 * reads it once for all its collectors.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} id the collector's module name, its section's name.
 * @param {?Meta} meta the collector's meta.
 * @param {?Result<MainSettings>} main_res main(uci), when read already.
 * @returns {Result<Settings>} its settings, or CONFIG_INVALID.
 */
export function settings(uci, id, meta, main_res) {
	main_res ??= main(uci);

	let exec = ('exec' in (meta?.needs ?? []));
	let seconds = exec ? default_timeout(uci, meta, main_res) : null;
	let own = uci.get_all(NAME, id);

	// Without a section of its own, as most collectors are: every setting is
	// its default, which needs no spec to check a value against. A scrape
	// reads the settings of each collector it runs.
	if (type(own) != 'object' || own['.type'] != 'collector')
		return Result.ok({
			enabled: ENABLED.default, timeout: seconds, budget: default_budget(uci, seconds, main_res),
			max_samples: default_max_samples(uci, meta, main_res), options: defaults(meta?.options ?? {}),
		});

	let timeout_res = exec ? section(uci, id, 'collector', { timeout: { default: seconds, ...TIMEOUT } }) : null;
	let timeout = (timeout_res?.ok) ? timeout_res.data.timeout : seconds;
	let core_specs = core(meta, seconds, default_budget(uci, timeout, main_res), default_max_samples(uci, meta, main_res));
	let res = section(uci, id, 'collector', { ...(meta?.options ?? {}), ...core_specs });

	if (!res.ok)
		return res;

	let options = res.data;
	let out = { enabled: options.enabled, timeout: options.timeout ?? null, budget: options.budget, max_samples: options.max_samples };

	for (let name in RESERVED)
		delete options[name];

	return Result.ok({ ...out, options });
};

/**
 * The collector's own options, as a Result: what `collect` gets. The core's are
 * checked too, and left out.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} id the collector's module name, its section's name.
 * @param {?Meta} meta the collector's meta.
 * @returns {Result<Object>} its options, typed, by name.
 */
export function collector(uci, id, meta) {
	let res = settings(uci, id, meta);

	return res.ok ? Result.ok(res.data.options) : res;
};

/**
 * Whether a collector is enabled: true unless its section says otherwise. A
 * value that is not a boolean counts as enabled, so the collector runs and
 * fails with CONFIG_INVALID, saying what is wrong.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string} id the collector's module name, its section's name.
 * @returns {boolean} whether it is enabled.
 */
export function enabled(uci, id) {
	let res = section(uci, id, 'collector', { enabled: ENABLED });

	return !res.ok || res.data.enabled;
};

/**
 * Those of the collectors `ids` that are not enabled (enabled()), with one
 * read of the config for them all: a scrape asks it of every collector
 * installed.
 *
 * @param {UciCursor} uci the cursor.
 * @param {string[]} ids the collectors' module names, their sections' names.
 * @returns {string[]} those switched off, in the order of `ids`.
 */
export function disabled(uci, ids) {
	let off = {};

	uci.foreach(NAME, 'collector', function(s) {
		if (!('enabled' in s))
			return;

		let res = convert('enabled', s.enabled, ENABLED);

		if (res.ok && !res.data)
			off[s['.name']] = true;
	});

	return filter(ids, (id) => off[id]);
};
