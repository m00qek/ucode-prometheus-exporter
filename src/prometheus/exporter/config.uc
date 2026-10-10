/**
 * Options from /etc/config/prometheus-exporter.
 *
 * @module prometheus_exporter_config
 */

'use strict';

import * as Result from 'prometheus.exporter.result';
import * as errors from 'prometheus.exporter.errors';
import * as types from 'prometheus.exporter.config.types';
import * as problems from 'prometheus.exporter.config.problems';

/**
 * An option as it is declared.
 *
 * @typedef {{ default: ?(boolean|int|string), title: ?string, help: string, datatype: ?string, secret: ?boolean }} OptionSpec
 */

/**
 * Every setting of a collector, as settings() gives them.
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

export const TRUE = types.TRUE;
export const FALSE = types.FALSE;
export const DATATYPES = types.DATATYPES;
export const datatype = types.datatype;
export const convert = types.convert;

export const OWNED_ROOTS = types.OWNED_ROOTS;
export const is_owned_directory = types.is_owned_directory;

export const PROBLEMS = problems.CODES;
export const problem = problems.problem;
export const english = problems.english;
export const invalid = types.invalid;

/** The service's name: its uci config, init script, command and ubus object. */
export const NAME = 'prometheus-exporter';

/** The apk package of the exporter; each collector package is PACKAGE-<name>. */
export const PACKAGE = 'ucode-prometheus-exporter';

/** The seconds a collector's programs get in all in each scrape, by default. */
export const EXEC_TIMEOUT = 5;

/** The seconds uhttpd gives the handler to answer a request (its -t). */
export const SCRIPT_TIMEOUT = 60;

/** The most seconds they may get: half of what uhttpd gives a scrape. */
export const EXEC_TIMEOUT_MAX = SCRIPT_TIMEOUT / 2;

const EXEC_TIMEOUT_RANGE = `range(1,${EXEC_TIMEOUT_MAX})`;

/** The seconds a scrape has when the scraper does not say. */
export const SCRAPE_TIMEOUT = 10;

/** The seconds a collector may take in a scrape before its breaker trips, by default. */
export const COLLECTOR_BUDGET = 5;

const SECONDS_RANGE = `range(1,${SCRIPT_TIMEOUT})`;

/** The samples a collector may write in a scrape, by default. */
export const MAX_SAMPLES = 20000;

/** The most max_samples may be: some 50 MB of samples in one scrape. */
export const MAX_SAMPLES_MAX = 100000;

const SAMPLES_RANGE = `range(1,${MAX_SAMPLES_MAX})`;

/** The samples the collectors of one reply may write in all. */
export const MAX_SCRAPE_SAMPLES = 200000;

/** The most max_scrape_samples may be. */
export const MAX_SCRAPE_SAMPLES_MAX = 1000000;

/** The main section's options the exporter itself reads. */
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

/** What every collector has besides its own options: the core's. */
export const ENABLED = { default: true, title: 'Enabled', help: 'Serve this collector; 0 leaves it out, and naming it in a query is a 400.' };

/** The core's timeout option of a collector that runs programs, without its default. */
export const TIMEOUT = {
	title: 'Program timeout',
	datatype: EXEC_TIMEOUT_RANGE,
	help: 'Seconds the programs of this collector get in all in each scrape; one still running then is killed.',
};

/** The core's budget option of every collector, without its default. */
export const BUDGET = {
	title: 'Budget',
	datatype: SECONDS_RANGE,
	help: 'Seconds this collector may take in a scrape; one still running then is stopped, and quarantined for a few scrapes.',
};

/** The core's max_samples option of every collector, without its default. */
export const SAMPLES = {
	title: 'Sample limit',
	datatype: SAMPLES_RANGE,
	help: 'Samples this collector may write in a scrape; one that writes more fails, and none of its samples are served.',
};

/** The option names the core keeps for itself: no collector declares them. */
export const RESERVED = [ 'enabled', 'timeout', 'budget', 'max_samples' ];

/**
 * The core's options of a collector with this meta, by name.
 *
 * @param {?Meta} meta
 * @param {?int} seconds
 * @param {?int} budget
 * @param {?int} samples
 * @returns {Object<string, OptionSpec>}
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
 * @param {Object<string, OptionSpec>} specs
 * @returns {Object}
 */
export function defaults(specs) {
	let out = {};

	for (let key, spec in specs)
		out[key] = spec.default;

	return out;
};

/**
 * The options of section `name`, of type `stype`, as `specs` declare them.
 *
 * @param {UciCursor} uci
 * @param {string} name
 * @param {string} stype
 * @param {Object<string, OptionSpec>} specs
 * @param {?string} pkg
 * @returns {Result<Object>}
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
 * @param {UciCursor} uci
 * @returns {Result<MainSettings>}
 */
export function main(uci) {
	return section(uci, 'main', NAME, MAIN_OPTIONS);
};

/** The least memory_limit but 0, in MB. */
export const MEMORY_LIMIT_MIN = 8;

/** The main section's options the init script reads, with its defaults. */
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

/** The config of basic auth's hash, apart from the exporter's own. */
export const AUTH_CONFIG = `${NAME}-auth`;

/** Its section: `config auth 'main'`. */
export const AUTH_SECTION = 'main';

/** The type of its section. */
export const AUTH_TYPE = 'auth';

/** The options of AUTH_CONFIG's section: the hash of basic auth's password. */
export const AUTH_OPTIONS = {
	auth_password: {
		default: '', datatype: 'crypt', secret: true,
		help: 'The crypt hash of the password of auth_user: $1$ (uhttpd -m), $5$ or $6$, as the ubus object\'s hash_password makes it.',
	},
};

/**
 * The hash of basic auth's password as AUTH_CONFIG holds it, checked.
 *
 * @param {UciCursor} uci
 * @returns {Result<{ auth_password: string }>}
 */
export function auth_values(uci) {
	return section(uci, AUTH_SECTION, AUTH_TYPE, AUTH_OPTIONS, AUTH_CONFIG);
};

/** memory_limit when it is 0: a quarter of the RAM, at most MEMORY_LIMIT_MAX MB. */
export const MEMORY_LIMIT_MAX = 64;

/** The share of the RAM memory_limit 0 takes: a quarter (see MEMORY_LIMIT_MAX). */
export const MEMORY_LIMIT_SHARE = 4;

/**
 * The MB memory_limit `mb` makes on a device of `total_kb` kB of RAM.
 *
 * @param {int} mb
 * @param {int} total_kb
 * @returns {int}
 */
export function memory_limit_mb(mb, total_kb) {
	return (mb > 0) ? mb : min(MEMORY_LIMIT_MAX, int(total_kb / 1024 / MEMORY_LIMIT_SHARE));
};

/**
 * The init script's options, each alone: what it would misread.
 *
 * @param {UciCursor} uci
 * @returns {Result<ServiceSettings>}
 */
export function service_values(uci) {
	let res = section(uci, 'main', NAME, SERVICE_OPTIONS);

	if (res.ok && res.data.listen_interface == '')
		return invalid('listen_interface', problems.problem(problems.INTERFACE), '');
	if (!res.ok)
		return res;

	let hash = (res.data.auth_user != '') ? auth_values(uci) : Result.ok(defaults(AUTH_OPTIONS));

	return hash.ok ? Result.ok({ ...res.data, ...hash.data }) : hash;
};

/**
 * What is wrong of the init script's options that go together, by option.
 *
 * @param {ServiceSettings} options
 * @returns {Object<string, Problem>}
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
 * The init script's options, checked as start checks them.
 *
 * @param {UciCursor} uci
 * @returns {Result<ServiceSettings>}
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
 * Basic auth as auth_user and AUTH_CONFIG's hash set it.
 *
 * @param {UciCursor} uci
 * @returns {Result<?BasicAuth>}
 */
export function auth(uci) {
	let res = service(uci);

	if (!res.ok)
		return res;

	return Result.ok(res.data.auth_user != '' ? { user: res.data.auth_user, hash: res.data.auth_password } : null);
};

/**
 * The seconds a collector's programs get when its section sets no timeout.
 *
 * @param {UciCursor} uci
 * @param {?Meta} meta
 * @param {?Result<MainSettings>} main_res
 * @returns {int}
 */
export function default_timeout(uci, meta, main_res) {
	if (meta?.timeout != null)
		return meta.timeout;

	let res = main_res ?? main(uci);

	return res.ok ? res.data.exec_timeout : EXEC_TIMEOUT;
};

/**
 * The seconds a collector may take when its section sets no budget.
 *
 * @param {UciCursor} uci
 * @param {?int} timeout
 * @param {?Result<MainSettings>} main_res
 * @returns {int}
 */
export function default_budget(uci, timeout, main_res) {
	let res = main_res ?? main(uci);
	let budget = res.ok ? res.data.collector_budget : COLLECTOR_BUDGET;

	return (timeout != null) ? max(budget, timeout + 1) : budget;
};

/**
 * The samples a collector may write when its section sets no max_samples.
 *
 * @param {UciCursor} uci
 * @param {?Meta} meta
 * @param {?Result<MainSettings>} main_res
 * @returns {int}
 */
export function default_max_samples(uci, meta, main_res) {
	if (meta?.max_samples != null)
		return meta.max_samples;

	let res = main_res ?? main(uci);

	return res.ok ? res.data.max_samples : MAX_SAMPLES;
};

/**
 * Where a collector's budget comes from.
 *
 * @param {UciCursor} uci
 * @param {string} id
 * @param {?int} timeout
 * @returns {string}
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
 * Where a collector's seconds come from; null for one that runs no programs.
 *
 * @param {UciCursor} uci
 * @param {string} id
 * @param {?Meta} meta
 * @returns {?string}
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
 * `config collector '<id>'`: the collector's module name.
 *
 * @param {UciCursor} uci
 * @param {string} id
 * @param {?Meta} meta
 * @param {?Result<MainSettings>} main_res
 * @returns {Result<Settings>}
 */
export function settings(uci, id, meta, main_res) {
	main_res ??= main(uci);

	let exec = ('exec' in (meta?.needs ?? []));
	let seconds = exec ? default_timeout(uci, meta, main_res) : null;
	let own = uci.get_all(NAME, id);

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
 * The collector's own options, as a Result: what `collect` gets.
 *
 * @param {UciCursor} uci
 * @param {string} id
 * @param {?Meta} meta
 * @returns {Result<Object>}
 */
export function collector(uci, id, meta) {
	let res = settings(uci, id, meta);

	return res.ok ? Result.ok(res.data.options) : res;
};

/**
 * Whether a collector is enabled: true unless its section says otherwise.
 *
 * @param {UciCursor} uci
 * @param {string} id
 * @returns {boolean}
 */
export function enabled(uci, id) {
	let res = section(uci, id, 'collector', { enabled: ENABLED });

	return !res.ok || res.data.enabled;
};

/**
 * Those of the collectors `ids` that are not enabled, from one read of the config.
 *
 * @param {UciCursor} uci
 * @param {string[]} ids
 * @returns {string[]}
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
