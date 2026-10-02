'use strict';

// The collector API: the one module a collector imports. The loader, the
// command line's `collector check` and the tests refuse a collector that
// imports any other (loader.import_problem): what a collector touches of the
// system comes through the capabilities collect() gets in `deps`, and what it
// takes of the exporter's code comes from here. What this module exports is
// what a major version protects, for collectors of every package: the modules
// behind it are the core's, and change as it does.
//
//   Result      what collect() returns: ok, err, none; is, is_none, describe
//   errors      the codes a collector fails with, and those its capabilities
//               fail with, which it may tell apart
//   services    whether a service is watched, for nothing to observe
//               (prometheus_exporter.services)
//   proc        reading procfs and sysfs through deps.fs
//               (prometheus_exporter.proc)
//   exposition  the exposition format's parse, format_value and sanitize
//
// Each is an object of exactly the names below, so what a collector may use
// is listed here, not whatever the modules behind it happen to export.
//
// Every collector is compiled with its own copy of each module it imports,
// this one and what it imports: so this one imports only what is small.
// The exposition format's modules are a third of the exporter's code, and
// three collectors use them: exposition's functions load them the first time
// one is called, in the process that calls it.

import * as result from 'prometheus_exporter.result';
import * as codes from 'prometheus_exporter.errors';
import * as watched from 'prometheus_exporter.services';
import * as procfs from 'prometheus_exporter.proc';

export const Result = {
	ok: result.ok,
	err: result.err,
	none: result.none,
	is: result.is,
	is_none: result.is_none,
	describe: result.describe,
};

export const errors = {
	// What a collector fails with, of its own.
	SOURCE_UNREADABLE: codes.SOURCE_UNREADABLE,
	SOURCE_INVALID: codes.SOURCE_INVALID,
	CONFIG_INVALID: codes.CONFIG_INVALID,

	// What its capabilities fail with: deps.ubus, deps.rtnl, deps.nl80211,
	// deps.socket, deps.exec, and out.parse and exposition.parse.
	UBUS_CONNECT_FAILED: codes.UBUS_CONNECT_FAILED,
	UBUS_CALL_FAILED: codes.UBUS_CALL_FAILED,
	NL80211_FAILED: codes.NL80211_FAILED,
	RTNL_FAILED: codes.RTNL_FAILED,
	SOCKET_FAILED: codes.SOCKET_FAILED,
	COMMAND_NOT_ALLOWED: codes.COMMAND_NOT_ALLOWED,
	COMMAND_FAILED: codes.COMMAND_FAILED,
	COMMAND_TIMEOUT: codes.COMMAND_TIMEOUT,
	SCRAPE_DEADLINE: codes.SCRAPE_DEADLINE,
	EXPOSITION_INVALID: codes.EXPOSITION_INVALID,
};

export const services = {
	ENABLED: watched.ENABLED,
	DISABLED: watched.DISABLED,
	NOT_INSTALLED: watched.NOT_INSTALLED,
	NOT_FOUND: watched.NOT_FOUND,
	state: watched.state,
	idle: watched.idle,
	unless_disabled: watched.unless_disabled,
	object_missing: watched.object_missing,
};

export const proc = {
	first_line: procfs.first_line,
	lines: procfs.lines,
	each_line: procfs.each_line,
	fields: procfs.fields,
	auxv: procfs.auxv,
	AT_PAGESZ: procfs.AT_PAGESZ,
	AT_CLKTCK: procfs.AT_CLKTCK,
};

// prometheus_exporter.exposition's functions, loaded once they are called.
let format = null;

function exposition_fn(name) {
	return function(...args) {
		format ??= loadstring(
			"import { parse, format_value, sanitize } from 'prometheus_exporter.exposition';\n" +
			'return { parse, format_value, sanitize };',
			{ raw_mode: true })();

		return format[name](...args);
	};
}

export const exposition = {
	parse: exposition_fn('parse'),
	format_value: exposition_fn('format_value'),
	sanitize: exposition_fn('sanitize'),
};
