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
 * @param {*} obj
 * @returns {boolean}
 */
export function is(obj) {
	return type(obj) == 'object' && proto(obj)?.[MARK] === true;
};

/**
 * An ok Result of `data`.
 *
 * @template T
 * @param {T} data
 * @returns {Result<T>}
 */
export function ok(data) {
	return proto({ ok: true, data: data }, ResultMethods);
};

/**
 * Nothing to observe: a success without samples, and why in `none`.
 *
 * @param {?string} reason
 * @returns {Result<null>}
 */
export function none(reason) {
	return proto({ ok: true, data: null, none: '' + (reason ?? 'nothing there') }, ResultMethods);
};

/**
 * Whether a Result is none's: ok, with nothing to observe.
 *
 * @param {?Result} res
 * @returns {boolean}
 */
export function is_none(res) {
	return res?.ok === true && res.none != null;
};

/**
 * `details` is for the log; `data`, if any, for the caller to act on.
 *
 * @param {string} error
 * @param {?(string|Object)} details
 * @param {*} data
 * @returns {Result}
 */
export function err(error, details, data) {
	return proto({ ok: false, error: error, details: details, data: data }, ResultMethods);
};

/**
 * Only string details are shown: object details are diagnostics, not log text.
 *
 * @param {Result} res
 * @returns {string}
 */
export function describe(res) {
	return (type(res.details) == 'string' && length(res.details) > 0)
		? `${res.error} (${res.details})`
		: `${res.error}`;
};
