'use strict';

// Options from /etc/config/prometheus-exporter. Each is declared as
// { default, help, datatype, secret }: the default sets its type (a boolean
// takes uci's boolean spellings, an integer an integer, a string any single
// value), help is a sentence saying what it does, and the optional datatype,
// one of LuCI's names (and `regex`, `username` and `crypt`), narrows the values
// it takes as LuCI would. A secret option's value is never part of a message.
// Unset options take the default; options nobody declared are ignored, so an
// older config never breaks a scrape.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';
import * as crypt from 'prometheus_exporter.crypt';
import { is_user, is_hash, ROUNDS_MAX } from 'prometheus_exporter.auth';

// The service's name: its uci config (and the main section's type), its init
// script, its command, its libexec directory and its ubus object.
export const NAME = 'prometheus-exporter';

// The apk package of the exporter; each collector package is PACKAGE-<name>.
export const PACKAGE = 'ucode-prometheus-exporter';

// The seconds the programs a collector runs (exec) get in all in each scrape,
// unless it says otherwise. Prometheus gives a scrape 10 s by default
// (scrape_timeout): a collector whose program hangs for all of its 5 s still
// leaves the rest of the scrape, well under a second, time to answer. The
// programs collectors run answer in milliseconds (nft, ethtool, mmcli over
// D-Bus) or in a second or so (an ssh login to a radio).
export const EXEC_TIMEOUT = 5;

// The seconds uhttpd gives the handler to answer a request (its -t, which
// the init script sets), after which it kills the request, answering nothing.
export const SCRIPT_TIMEOUT = 60;

// The most seconds they may get: half of what uhttpd gives a scrape.
export const EXEC_TIMEOUT_MAX = SCRIPT_TIMEOUT / 2;

const EXEC_TIMEOUT_RANGE = `range(1,${EXEC_TIMEOUT_MAX})`;

// The seconds a scrape has when the scraper does not say
// (X-Prometheus-Scrape-Timeout-Seconds, which Prometheus and vmagent send):
// Prometheus's own default scrape_timeout, and vmagent's.
export const SCRAPE_TIMEOUT = 10;

// The seconds a collector may take in a scrape before its breaker trips
// (prometheus_exporter.breaker), unless it says otherwise: half of
// Prometheus's default timeout. Every collector takes a small part of it on
// a router: a typical full scrape takes a 500-MIPS MIPS router 2 seconds in
// all; only nat_traffic on a table of tens of thousands goes past it.
export const COLLECTOR_BUDGET = 5;

const SECONDS_RANGE = `range(1,${SCRIPT_TIMEOUT})`;

// The samples a collector may write in a scrape, unless it says otherwise
// (meta.max_samples, or its section's max_samples): one that writes more fails
// with SAMPLE_LIMIT, and the scrape keeps none of them. The most any collector
// writes on the benchmark's large world, a router busier than most, is 3,650
// (snmp6 on 50 devices; ethtool writes 1,980 on 17 ports, wifi 2,502 for 100
// stations), and some 0.5 kB of memory each while a scrape holds them: 20,000
// leaves five times that, and bounds what a runaway holds to some 10 MB.
// nat_traffic, whose samples are the connection table's address pairs, says
// more.
export const MAX_SAMPLES = 20000;

// The most max_samples may be: some 50 MB of samples in one scrape.
export const MAX_SAMPLES_MAX = 100000;

const SAMPLES_RANGE = `range(1,${MAX_SAMPLES_MAX})`;

// The main section's options the exporter itself reads; the others are the
// init script's (SERVICE_OPTIONS).
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
};

// What every collector has besides its own options: the core's.
export const ENABLED = { default: true, help: 'Serve this collector; 0 leaves it out, and naming it in a query is a 400.' };

// The core's option of a collector that runs programs (exec in meta.needs),
// without its default, which is the collector's meta.timeout or else the main
// section's exec_timeout (default_timeout).
export const TIMEOUT = {
	datatype: EXEC_TIMEOUT_RANGE,
	help: 'Seconds the programs of this collector get in all in each scrape; one still running then is killed.',
};

// The core's option of every collector, without its default, which is the
// main section's collector_budget, or for a collector that runs programs its
// timeout and a second more when that is longer (default_budget).
export const BUDGET = {
	datatype: SECONDS_RANGE,
	help: 'Seconds this collector may take in a scrape; one still running then is stopped, and quarantined for a few scrapes.',
};

// The core's option of every collector, without its default, which is its
// meta.max_samples or else the main section's max_samples
// (default_max_samples).
export const SAMPLES = {
	datatype: SAMPLES_RANGE,
	help: 'Samples this collector may write in a scrape; one that writes more fails, and none of its samples are served.',
};

// The option names the core keeps for itself: no collector declares them.
// `timeout` is only an exec collector's; the others ignore it.
export const RESERVED = [ 'enabled', 'timeout', 'budget', 'max_samples' ];

// The core's options of a collector with this meta, by name: enabled;
// timeout, whose default is `seconds`, when it runs programs; budget, whose
// default is `budget` (COLLECTOR_BUDGET without one); and max_samples, whose
// default is `samples` (MAX_SAMPLES without one).
export function core(meta, seconds, budget, samples) {
	let out = { enabled: ENABLED };

	if ('exec' in (meta?.needs ?? []))
		out.timeout = { default: seconds, ...TIMEOUT };

	out.budget = { default: budget ?? COLLECTOR_BUDGET, ...BUDGET };
	out.max_samples = { default: samples ?? MAX_SAMPLES, ...SAMPLES };

	return out;
};

// The spellings of a boolean uci value, as uci's own tools take them.
export const TRUE = [ '1', 'yes', 'on', 'true', 'enabled' ];
export const FALSE = [ '0', 'no', 'off', 'false', 'disabled' ];

function absolute_path(v) {
	return substr(v, 0, 1) == '/' && !match(v, /[[:cntrl:]]/);
}

// The datatypes the core enforces, by LuCI's names: what value type each
// takes, what it calls a valid value, and whether a value is one. Syntactic
// only: a directory or file is an absolute path, not one that exists. Besides
// LuCI's, regex, and username and crypt, basic auth's user and hash. A
// datatype's `why`, when it has one, says what it expected of a value it does
// not take, instead of `expected`: crypt's, of a hash of too many rounds.
export const DATATYPES = {
	username: { types: [ 'string' ], expected: 'a user of 1 to 64 characters, without ":", spaces or control characters', check: is_user },
	crypt: {
		types: [ 'string' ],
		expected: 'a crypt hash: $1$ (uhttpd -m), $5$ or $6$',
		check: is_hash,
		why: (v) => crypt.is_hash(v)
			? `a hash of at most ${ROUNDS_MAX} rounds, which a scrape computes to check the password (hash_password makes one of 1000; one without rounds= has 5000)`
			: null,
	},
	uinteger: { types: [ 'int' ], expected: 'an integer of 0 or more', check: (v) => v >= 0 },
	directory: { types: [ 'string' ], expected: 'an absolute path', check: absolute_path },
	file: { types: [ 'string' ], expected: 'an absolute path', check: absolute_path },
	regex: {
		types: [ 'string' ],
		expected: 'a regular expression',
		check: function(v) {
			try {
				regexp(v);
				return true;
			} catch (e) {
				return false;
			}
		},
	},
};

// { types, expected, check } of a datatype name, or null for one the core does
// not know. range(min,max) takes the integers from min to max.
export function datatype(name) {
	let m = (type(name) == 'string') ? match(name, /^range\((-?[0-9]+),(-?[0-9]+)\)$/) : null;

	if (m) {
		let lo = int(m[1]), hi = int(m[2]);

		return lo <= hi ? { types: [ 'int' ], expected: `an integer from ${lo} to ${hi}`, check: (v) => v >= lo && v <= hi } : null;
	}

	return (type(name) == 'string') ? DATATYPES[name] : null;
};

// What option `spec` expected of a value it does not take: and what it got,
// unless the option is a secret.
function invalid(name, expected, value, spec) {
	return Result.err(errors.CONFIG_INVALID,
		`${name}: expected ${expected}` + (spec?.secret ? '' : `, got ${sprintf('%J', value)}`));
}

// A uci value as the type of the option's default.
function typed(name, value, spec) {
	switch (type(spec.default)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, 'a boolean', value, spec);

	case 'int':
		if (type(value) == 'string' && match(value, /^-?[0-9]+$/))
			return Result.ok(int(value));
		return invalid(name, 'an integer', value, spec);

	case 'string':
		if (type(value) == 'string')
			return Result.ok(value);
		return invalid(name, 'a single value', value, spec);
	}

	die(`option ${name}: unsupported default ${sprintf('%J', spec.default)}`);
}

// A uci value as option `spec` ({ default, datatype, secret }) takes it.
export function convert(name, value, spec) {
	let res = typed(name, value, spec);
	let dt = (res.ok && spec.datatype != null) ? datatype(spec.datatype) : null;

	if (dt && !dt.check(res.data))
		return invalid(name, (dt.why ? dt.why(res.data) : null) ?? dt.expected, res.data, spec);

	return res;
};

// The defaults of options declared as { default, ... }.
export function defaults(specs) {
	let out = {};

	for (let key, spec in specs)
		out[key] = spec.default;

	return out;
};

// The options of section `name`, of section type `stype`, as `specs` declare them.
export function section(uci, name, stype, specs) {
	let s = uci.get_all(NAME, name);
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

export function main(uci) {
	return section(uci, 'main', NAME, MAIN_OPTIONS);
};

// The main section's options the init script reads, with its defaults: whether
// the service runs, where uhttpd listens, its TLS files ('' for none), and the
// user and password hash of basic auth ('' for none).
export const SERVICE_OPTIONS = {
	enabled: { default: true, help: 'Run the service; 0 stops it.' },
	listen_interface: { default: 'loopback', help: 'The logical interface uhttpd listens on, or * for every address.' },
	listen_port: { default: 9100, datatype: 'range(1,65535)', help: 'The port uhttpd listens on.' },
	http_keepalive: { default: 70, datatype: 'uinteger', help: 'Seconds an idle connection is kept open; 0 for none.' },
	cert: { default: '', help: 'The certificate to serve HTTPS with, along with key.' },
	key: { default: '', help: 'The private key of cert.' },
	auth_user: { default: '', datatype: 'username', help: 'The user a scrape logs in as (basic auth), with auth_password; HTTPS only.' },
	auth_password: {
		default: '', datatype: 'crypt', secret: true,
		help: 'The crypt hash of the password of auth_user: $1$ (uhttpd -m), $5$ or $6$, as the ubus object\'s hash_password makes it.',
	},
	memory_limit: {
		default: 0, datatype: 'uinteger',
		help: 'MB of memory each of the exporter\'s processes may take (its data, RLIMIT_DATA): a collector that takes more fails alone. 0 for a quarter of the RAM, at most 64 MB.',
	},
};

// memory_limit when it is 0: a quarter of the RAM, at most MEMORY_LIMIT_MAX MB,
// which the init script works out (memory_limit_mb()). Measured as the peak
// resident memory of a scrape's child process (make bench): a typical
// router's full scrape 9 MB on a 64-bit CPU and 7 MB on a 32-bit MIPS one
// (QEMU), the benchmark's large world, a router busier than most, with every
// collector, 30 MB on 64 bits and 22 MB on the MIPS one. 64 MB leaves more than twice the largest, and
// a router with less RAM than 256 MB a quarter of what it has.
export const MEMORY_LIMIT_MAX = 64;
export const MEMORY_LIMIT_SHARE = 4;

// The MB memory_limit `mb` makes on a device of `total_kb` kB of RAM.
export function memory_limit_mb(mb, total_kb) {
	return (mb > 0) ? mb : min(MEMORY_LIMIT_MAX, int(total_kb / 1024 / MEMORY_LIMIT_SHARE));
};

// The init script's options, each alone: what it would misread.
export function service_values(uci) {
	let res = section(uci, 'main', NAME, SERVICE_OPTIONS);

	if (res.ok && res.data.listen_interface == '')
		return invalid('listen_interface', 'an interface name or *', '');

	return res;
};

// What is wrong of the init script's options that go together (`o`, typed),
// by option: basic auth's user and hash need each other, and both need cert
// and key, as Basic sends the password in the clear.
export function together(o) {
	let out = {};
	let user = (o.auth_user ?? '') != '', hash = (o.auth_password ?? '') != '';

	if (user && !hash)
		out.auth_password = 'basic auth needs the hash of a password along with auth_user';
	else if (hash && !user)
		out.auth_user = 'basic auth needs a user along with auth_password';

	if ((user || hash) && ((o.cert ?? '') == '' || (o.key ?? '') == ''))
		out[user ? 'auth_user' : 'auth_password'] ??= 'basic auth needs HTTPS: set cert and key, or the password crosses the network in the clear';

	return out;
};

// The init script's options, checked so that start refuses what it would
// misread, or serve without what it is told to (basic auth over HTTP).
export function service(uci) {
	let res = service_values(uci);

	if (!res.ok)
		return res;

	for (let name, msg in together(res.data))
		return Result.err(errors.CONFIG_INVALID, `${name}: ${msg}`);

	return res;
};

// Basic auth as the main section sets it: a Result of { user, hash }, or of
// null when it sets none; an error when the init script's options are not valid.
export function auth(uci) {
	let res = service(uci);

	if (!res.ok)
		return res;

	return Result.ok(res.data.auth_user != '' ? { user: res.data.auth_user, hash: res.data.auth_password } : null);
};

// The seconds a collector's programs get when its section sets no timeout:
// its meta.timeout, or else the main section's exec_timeout (its default while
// the main section is not valid, which check and the init script refuse).
export function default_timeout(uci, meta) {
	if (meta?.timeout != null)
		return meta.timeout;

	let res = main(uci);

	return res.ok ? res.data.exec_timeout : EXEC_TIMEOUT;
};

// The seconds a collector may take when its section sets no budget: the main
// section's collector_budget (its default while the main section is not
// valid); for a collector whose programs get `timeout` seconds, that and a
// second more when it is longer, as the watchdog counts whole seconds: a
// budget never quarantines what a timeout allows.
export function default_budget(uci, timeout) {
	let res = main(uci);
	let budget = res.ok ? res.data.collector_budget : COLLECTOR_BUDGET;

	return (timeout != null) ? max(budget, timeout + 1) : budget;
};

// The samples a collector may write when its section sets no max_samples:
// its meta.max_samples, or else the main section's max_samples (its default
// while the main section is not valid).
export function default_max_samples(uci, meta) {
	if (meta?.max_samples != null)
		return meta.max_samples;

	let res = main(uci);

	return res.ok ? res.data.max_samples : MAX_SAMPLES;
};

// Where a collector's budget comes from: its section's `budget`, the main
// section's `collector_budget`, or its `timeout`.
export function budget_source(uci, id, timeout) {
	let s = uci.get_all(NAME, id);

	if (type(s) == 'object' && s['.type'] == 'collector' && 'budget' in s)
		return 'budget';

	let res = main(uci);
	let budget = res.ok ? res.data.collector_budget : COLLECTOR_BUDGET;

	return (timeout != null && timeout + 1 > budget) ? 'timeout' : 'collector_budget';
};

// Where a collector's seconds come from: its section's `timeout`, its
// `meta.timeout` or the main section's `exec_timeout`; null for a collector
// that runs no programs.
export function timeout_source(uci, id, meta) {
	if (!('exec' in (meta?.needs ?? [])))
		return null;

	let s = uci.get_all(NAME, id);

	if (type(s) == 'object' && s['.type'] == 'collector' && 'timeout' in s)
		return 'timeout';

	return (meta.timeout != null) ? 'meta.timeout' : 'exec_timeout';
};

// `config collector '<id>'`: the collector's module name, as a uci section name
// cannot hold the '-' of ltq-dsl.
//
// Every setting of the collector with this meta, as a Result of { enabled,
// timeout, budget, max_samples, options }: the core's options (enabled;
// timeout when it runs programs, null otherwise; budget; max_samples) are
// checked like its own, which `options` holds. So timeout's precedence: the
// section's, then meta.timeout, then the main section's exec_timeout;
// budget's: the section's, then default_budget's; max_samples': the
// section's, then meta.max_samples, then the main section's.
export function settings(uci, id, meta) {
	let exec = ('exec' in (meta?.needs ?? []));
	let seconds = exec ? default_timeout(uci, meta) : null;
	let timeout_res = exec ? section(uci, id, 'collector', { timeout: { default: seconds, ...TIMEOUT } }) : null;
	let timeout = (timeout_res?.ok) ? timeout_res.data.timeout : seconds;
	let core_specs = core(meta, seconds, default_budget(uci, timeout), default_max_samples(uci, meta));
	let res = section(uci, id, 'collector', { ...(meta?.options ?? {}), ...core_specs });

	if (!res.ok)
		return res;

	let options = res.data;
	let out = { enabled: options.enabled, timeout: options.timeout ?? null, budget: options.budget, max_samples: options.max_samples };

	for (let name in RESERVED)
		delete options[name];

	return Result.ok({ ...out, options });
};

// The collector's own options, as a Result: what `collect` gets. The core's are
// checked too, and left out.
export function collector(uci, id, meta) {
	let res = settings(uci, id, meta);

	return res.ok ? Result.ok(res.data.options) : res;
};

// Whether a collector is enabled: true unless its section says otherwise. A
// value that is not a boolean counts as enabled, so the collector runs and
// fails with CONFIG_INVALID, saying what is wrong.
export function enabled(uci, id) {
	let res = section(uci, id, 'collector', { enabled: ENABLED });

	return !res.ok || res.data.enabled;
};
