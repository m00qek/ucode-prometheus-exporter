'use strict';

// Options from /etc/config/prometheus-exporter. Each is declared as
// { default, help, datatype }: the default sets its type (a boolean takes uci's
// boolean spellings, an integer an integer, a string any single value), help
// is a sentence saying what it does, and the optional datatype, one of LuCI's
// names (and `regex`), narrows the values it takes as LuCI would. Unset options
// take the default; options nobody declared are ignored, so an older config
// never breaks a scrape.

import * as Result from 'prometheus_exporter.result';
import * as errors from 'prometheus_exporter.errors';

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

// The most seconds they may get: half of the 60 s uhttpd gives a scrape before
// it kills it, answering nothing.
export const EXEC_TIMEOUT_MAX = 30;

const EXEC_TIMEOUT_RANGE = `range(1,${EXEC_TIMEOUT_MAX})`;

// The main section's options the exporter itself reads; the others are the
// init script's (SERVICE_OPTIONS).
export const MAIN_OPTIONS = {
	omit_zero_values: { default: false, help: 'Leave out counters that are 0, most of which never move on a router.' },
	exec_timeout: {
		default: EXEC_TIMEOUT, datatype: EXEC_TIMEOUT_RANGE,
		help: 'Seconds the programs a collector runs get in all in each scrape, unless the collector says otherwise; one still running then is killed.',
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

// The option names the core keeps for itself: no collector declares them.
// `timeout` is only an exec collector's; the others ignore it.
export const RESERVED = [ 'enabled', 'timeout' ];

// The core's options of a collector with this meta, by name: enabled, and
// timeout, whose default is `seconds`, when it runs programs.
export function core(meta, seconds) {
	let out = { enabled: ENABLED };

	if ('exec' in (meta?.needs ?? []))
		out.timeout = { default: seconds, ...TIMEOUT };

	return out;
};

const TRUE = [ '1', 'yes', 'on', 'true', 'enabled' ];
const FALSE = [ '0', 'no', 'off', 'false', 'disabled' ];

function absolute_path(v) {
	return substr(v, 0, 1) == '/' && !match(v, /[[:cntrl:]]/);
}

// The datatypes the core enforces, by LuCI's names: what value type each
// takes, what it calls a valid value, and whether a value is one. Syntactic
// only: a directory or file is an absolute path, not one that exists.
const DATATYPES = {
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

function invalid(name, expected, value) {
	return Result.err(errors.CONFIG_INVALID, `${name}: expected ${expected}, got ${sprintf('%J', value)}`);
}

// A uci value as the type of the option's default.
function typed(name, value, fallback) {
	switch (type(fallback)) {
	case 'bool':
		if (value in TRUE)
			return Result.ok(true);
		if (value in FALSE)
			return Result.ok(false);
		return invalid(name, 'a boolean', value);

	case 'int':
		if (type(value) == 'string' && match(value, /^-?[0-9]+$/))
			return Result.ok(int(value));
		return invalid(name, 'an integer', value);

	case 'string':
		if (type(value) == 'string')
			return Result.ok(value);
		return invalid(name, 'a single value', value);
	}

	die(`option ${name}: unsupported default ${sprintf('%J', fallback)}`);
}

// A uci value as option `spec` ({ default, datatype }) takes it.
export function convert(name, value, spec) {
	let res = typed(name, value, spec.default);
	let dt = (res.ok && spec.datatype != null) ? datatype(spec.datatype) : null;

	if (dt && !dt.check(res.data))
		return invalid(name, dt.expected, res.data);

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
// the service runs, where uhttpd listens, and its TLS files ('' for none).
export const SERVICE_OPTIONS = {
	enabled: { default: true, help: 'Run the service; 0 stops it.' },
	listen_interface: { default: 'loopback', help: 'The logical interface uhttpd listens on, or * for every address.' },
	listen_port: { default: 9100, datatype: 'range(1,65535)', help: 'The port uhttpd listens on.' },
	http_keepalive: { default: 70, datatype: 'uinteger', help: 'Seconds an idle connection is kept open; 0 for none.' },
	cert: { default: '', help: 'The certificate to serve HTTPS with, along with key.' },
	key: { default: '', help: 'The private key of cert.' },
};

// The init script's options, checked so that start refuses what it would
// misread.
export function service(uci) {
	let res = section(uci, 'main', NAME, SERVICE_OPTIONS);

	if (res.ok && res.data.listen_interface == '')
		return invalid('listen_interface', 'an interface name or *', '');

	return res;
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
// timeout, options }: the core's options (enabled, and timeout when it runs
// programs, null otherwise) are checked like its own, which `options` holds.
// So timeout's precedence: the section's, then meta.timeout, then the main
// section's exec_timeout.
export function settings(uci, id, meta) {
	let core_specs = core(meta, ('exec' in (meta?.needs ?? [])) ? default_timeout(uci, meta) : null);
	let res = section(uci, id, 'collector', { ...(meta?.options ?? {}), ...core_specs });

	if (!res.ok)
		return res;

	let options = res.data;
	let out = { enabled: options.enabled, timeout: options.timeout ?? null };

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
