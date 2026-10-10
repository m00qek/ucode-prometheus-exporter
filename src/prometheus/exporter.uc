/**
 * The collector API: the one module a collector imports.
 *
 * @module prometheus_exporter
 */

'use strict';

import * as result from 'prometheus.exporter.result';
import * as codes from 'prometheus.exporter.api.errors';
import * as watched from 'prometheus.exporter.services';
import * as procfs from 'prometheus.exporter.proc';
import * as format from 'prometheus.exporter.api.exposition';

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

/** What collect() returns: ok, err, none; is, is_none, describe (prometheus.exporter.result). Constant. */
export const Result = result;

/** The error codes a collector and its capabilities fail with. Constant. */
export const errors = codes;

/** Whether a service is watched, for nothing to observe (prometheus.exporter.services). Constant. */
export const services = watched;

/** Reading procfs and sysfs through deps.fs (prometheus.exporter.proc). Constant. */
export const proc = procfs;

/** The exposition format's functions, each loaded the first time it is called. Constant. */
export const exposition = format;

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
