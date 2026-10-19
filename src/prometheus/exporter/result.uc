/**
 * ok/err Result for fallible edges, and none: success with nothing to observe.
 *
 * @module prometheus_exporter_result
 */

'use strict';

import * as ResultMethods from 'prometheus.exporter.api.mark';

/**
 * What a fallible edge, or a collector's collect(), returns.
 *
 * @template T
 * @typedef {{ ok: boolean, data: T, error: ?string, details: ?(string|Object), none: ?string }} Result
 */

const MARK = 'prometheus_exporter_result';

/**
 * Whether `obj` is a Result, whichever copy of this module made it.
 *
 * @param {*} obj anything: what a collector returned, say.
 * @returns {boolean} whether it is a Result.
 */
export function is(obj) {
	return type(obj) == 'object' && proto(obj)?.[MARK] === true;
};

/**
 * An ok Result of `data`.
 *
 * @template T
 * @param {T} data the payload, null for none.
 * @returns {Result<T>} { ok: true, data }.
 */
export function ok(data) {
	return proto({ ok: true, data: data }, ResultMethods);
};

/**
 * Nothing to observe: a success without samples, and why in `none`.
 *
 * @param {?string} reason why there is nothing to observe; 'nothing there' when null.
 * @returns {Result<null>} { ok: true, data: null, none: reason }.
 */
export function none(reason) {
	return proto({ ok: true, data: null, none: '' + (reason ?? 'nothing there') }, ResultMethods);
};

/**
 * Whether a Result is none's: ok, with nothing to observe.
 *
 * @param {?Result} res a Result, or null.
 * @returns {boolean} whether it is ok and has `none`.
 */
export function is_none(res) {
	return res?.ok === true && res.none != null;
};

/**
 * `details` is for the log; `data`, if any, for the caller to act on.
 *
 * @param {string} error the error code, one of prometheus.exporter.errors' (or a collector's own).
 * @param {?(string|Object)} details for the log; describe() leaves an object out.
 * @param {*} data what the caller may act on, shaped by the edge ({ status } of a failed call).
 * @returns {Result} { ok: false, error, details, data }.
 */
export function err(error, details, data) {
	return proto({ ok: false, error: error, details: details, data: data }, ResultMethods);
};

/**
 * Only string details are shown: object details are diagnostics, not log text.
 *
 * @param {Result} res a failed Result.
 * @returns {string} 'CODE (details)', or 'CODE' without string details.
 */
export function describe(res) {
	return (type(res.details) == 'string' && length(res.details) > 0)
		? `${res.error} (${res.details})`
		: `${res.error}`;
};
