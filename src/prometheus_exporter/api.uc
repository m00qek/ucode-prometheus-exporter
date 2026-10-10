/**
 * The collector API: the one module a collector imports.
 *
 * @module prometheus_exporter_api
 */

'use strict';

import * as result from 'prometheus_exporter.result';
import * as codes from 'prometheus_exporter.errors';
import * as watched from 'prometheus_exporter.services';
import * as procfs from 'prometheus_exporter.proc';

/**
 * A collector's `meta`, as the loader validates it (loader.validate).
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
 * A collector's `collect(deps, out, options)`.
 *
 * @typedef {(deps: Deps, out: Recorder, options: Object) => Result} Collect
 */

/**
 * What a collector module exports: its meta and its collect.
 *
 * @typedef {{ meta: Meta, collect: Collect }} CollectorModule
 */

/** What collect() returns: ok, err, none; is, is_none, describe (prometheus_exporter.result). */
export const Result = {
	ok: result.ok,
	err: result.err,
	none: result.none,
	is: result.is,
	is_none: result.is_none,
	describe: result.describe,
};

/** The error codes a collector and its capabilities fail with. */
export const errors = {
	SOURCE_UNREADABLE: codes.SOURCE_UNREADABLE,
	SOURCE_INVALID: codes.SOURCE_INVALID,
	CONFIG_INVALID: codes.CONFIG_INVALID,

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

/** Whether a service is watched, for nothing to observe (prometheus_exporter.services). */
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

/** Reading procfs and sysfs through deps.fs (prometheus_exporter.proc). */
export const proc = {
	first_line: procfs.first_line,
	lines: procfs.lines,
	each_line: procfs.each_line,
	fields: procfs.fields,
	rows: procfs.rows,
	auxv: procfs.auxv,
	AT_PAGESZ: procfs.AT_PAGESZ,
	AT_CLKTCK: procfs.AT_CLKTCK,
};

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

/** The exposition format's functions, each loaded the first time it is called. */
export const exposition = {
	parse: exposition_fn('parse'),
	format_value: exposition_fn('format_value'),
	sanitize: exposition_fn('sanitize'),
};

function unsigned(v, bits) {
	return (type(v) == 'int' && v < 0 && v >= -(1 << (bits - 1))) ? v + (1 << bits) : v;
}

/**
 * A ubus INT16, which ucode's ubus gives signed, as the unsigned integer meant.
 *
 * @param {*} v
 * @returns {*}
 */
export function u16(v) {
	return unsigned(v, 16);
};

/**
 * A ubus INT32, which ucode's ubus gives signed, as the unsigned integer meant.
 *
 * @param {*} v
 * @returns {*}
 */
export function u32(v) {
	return unsigned(v, 32);
};
