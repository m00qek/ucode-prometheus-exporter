/**
 * The collector API: the one module a collector imports. The loader, the
 * command line's `collector check` and the tests refuse a collector that
 * imports any other (loader.import_problem): what a collector touches of the
 * system comes through the capabilities collect() gets in `deps`, and what it
 * takes of the exporter's code comes from here. What this module exports is
 * what a major version protects, for collectors of every package: the modules
 * behind it are the core's, and change as it does.
 *
 *   Result      what collect() returns: ok, err, none; is, is_none, describe
 *   errors      the codes a collector fails with, and those its capabilities
 *               fail with, which it may tell apart
 *   services    whether a service is watched, for nothing to observe
 *               (prometheus_exporter.services)
 *   proc        reading procfs and sysfs through deps.fs
 *               (prometheus_exporter.proc)
 *   exposition  the exposition format's parse, format_value and sanitize
 *   u16, u32    a ubus integer as the unsigned one its sender meant
 *
 * Each of the first five is an object of exactly the names below, so what a
 * collector may use is listed here, not whatever the modules behind it happen
 * to export.
 *
 * Every collector is compiled with its own copy of each module it imports,
 * this one and what it imports: so this one imports only what is small.
 * The exposition format's modules are a third of the exporter's code, and
 * three collectors use them: exposition's functions load them the first time
 * one is called, in the process that calls it.
 *
 * What a collector module is, for the language server: CollectorModule,
 * its Meta and its Collect, typedefs of this module; collect() gets Deps
 * (prometheus_exporter.deps), a Recorder (prometheus_exporter.exposition) and
 * its options, and returns a Result (prometheus_exporter.result). A
 * collector's docs name them: @param {Deps} deps.
 *
 * @module prometheus_exporter_api
 */

'use strict';

import * as result from 'prometheus_exporter.result';
import * as codes from 'prometheus_exporter.errors';
import * as watched from 'prometheus_exporter.services';
import * as procfs from 'prometheus_exporter.proc';

/**
 * A collector's `meta`, as the loader validates it (loader.validate):
 *   name               [a-z0-9][a-z0-9_-]*, the module's name with _ for -
 *   title              a label of 1 to 40 characters
 *   help               a sentence: what it collects, and from where
 *   needs              the capabilities it gets in deps, once each
 *                      (deps.NEEDS)
 *   configs            with uci: the uci configs it reads
 *   commands           with exec: the programs it runs
 *   optional_commands  those of commands it runs only where installed
 *   timeout            with exec: the seconds its programs get, 1 to 30
 *   max_samples        the samples it may write, 1 to 100000
 *   cost               'light' (the default) or 'heavy' (loader.COSTS)
 *   options            its own options, by name (config's OptionSpec)
 *   paths              what it reads outside procfs and sysfs: a path
 *                      (whose {option}s name string options), { path,
 *                      owned: true }, or a function of its options and uci
 *                      handles that gives paths (prometheus_exporter.jail)
 *   ubus               with ubus: the objects and methods it calls,
 *                      { object: [ method ] }; an object 'name.*' for every
 *                      object whose name starts with 'name.', methods a
 *                      function of its options where an option decides
 *   capabilities       the capabilities it needs: CAP_NET_ADMIN, CAP_NET_RAW
 *   groups             the groups whose sockets it connects to
 *   proc_files         with fs: the files of /proc that only root reads,
 *                      which it reads (prometheus_exporter.privileges)
 *
 * @typedef {{
 *   name: string,
 *   title: string,
 *   help: string,
 *   needs: string[],
 *   configs: ?string[],
 *   commands: ?string[],
 *   optional_commands: ?string[],
 *   timeout: ?int,
 *   max_samples: ?int,
 *   cost: ?string,
 *   options: ?Object<string, OptionSpec>,
 *   paths: ?(string|{ path: string, owned: boolean }|function(Object, Object<string, UciHandle>): string[])[],
 *   ubus: ?Object<string, (string[]|function(Object): string[])>,
 *   capabilities: ?string[],
 *   groups: ?string[],
 *   proc_files: ?string[]
 * }} Meta
 */

/**
 * A collector's `collect(deps, out, options)`: deps, one capability per
 * need; out, the recorder it writes its families to; options, its own,
 * typed. It returns a Result: ok, err or none.
 *
 * @typedef {(deps: Deps, out: Recorder, options: Object) => Result} Collect
 */

/**
 * What a collector module exports: its meta and its collect.
 *
 * @typedef {{ meta: Meta, collect: Collect }} CollectorModule
 */

/**
 * What collect() returns: ok, err, none; is, is_none, describe
 * (prometheus_exporter.result).
 */
export const Result = {
	ok: result.ok,
	err: result.err,
	none: result.none,
	is: result.is,
	is_none: result.is_none,
	describe: result.describe,
};

/**
 * The codes a collector fails with, and those its capabilities fail with,
 * which it may tell apart (prometheus_exporter.errors).
 */
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
	UBUS_NOT_ALLOWED: codes.UBUS_NOT_ALLOWED,
	PERMISSION_DENIED: codes.PERMISSION_DENIED,
	SCRAPE_DEADLINE: codes.SCRAPE_DEADLINE,
	EXPOSITION_INVALID: codes.EXPOSITION_INVALID,
};

/**
 * Whether a service is watched, for nothing to observe
 * (prometheus_exporter.services).
 */
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

/**
 * Reading procfs and sysfs through deps.fs (prometheus_exporter.proc).
 */
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

/**
 * The exposition format's parse, format_value and sanitize
 * (prometheus_exporter.exposition), each loaded the first time it is called.
 */
export const exposition = {
	parse: exposition_fn('parse'),
	format_value: exposition_fn('format_value'),
	sanitize: exposition_fn('sanitize'),
};

// ucode's ubus gives a blobmsg INT16 or INT32 as a signed integer (lib/ubus.c),
// whatever its sender meant: a daemon's blobmsg_add_u32() of 4294967295 is -1.
function unsigned(v, bits) {
	return (type(v) == 'int' && v < 0 && v >= -(1 << (bits - 1))) ? v + (1 << bits) : v;
}

/**
 * A ubus INT16 as the unsigned integer its sender meant (blobmsg_add_u16()):
 * ucode's ubus gives it signed, so a port of 51820 arrives as -13716. Anything
 * that is not a negative 16-bit integer is given back as it is, null and the
 * other types included, for the collector to check as it would have.
 *
 * @param {*} v anything a ubus reply holds; only a negative 16-bit integer
 *   changes.
 * @returns {*} v, unsigned when it is a negative 16-bit integer.
 */
export function u16(v) {
	return unsigned(v, 16);
};

/**
 * A ubus INT32 as the unsigned integer its sender meant (blobmsg_add_u32()):
 * ucode's ubus gives it signed, so a counter past 2147483647 arrives negative,
 * and a (uint32_t)-1 as -1. Anything that is not a negative 32-bit integer is
 * given back as it is, null and the other types included, for the collector
 * to check as it would have.
 *
 * @param {*} v anything a ubus reply holds; only a negative 32-bit integer
 *   changes.
 * @returns {*} v, unsigned when it is a negative 32-bit integer.
 */
export function u32(v) {
	return unsigned(v, 32);
};
