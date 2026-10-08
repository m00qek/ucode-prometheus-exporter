/**
 * ok/err Result for fallible edges (the pattern of wgpathd and luci-sso), and
 * none: a collector's success with nothing to observe.
 *
 * @module prometheus_exporter_result
 */

'use strict';

/**
 * What a fallible edge returns, and what a collector's collect() does: ok()'s
 * { ok: true, data }, none()'s { ok: true, data: null, none } and err()'s
 * { ok: false, error, details, data }, each with the prototype is() knows it
 * by. `data` is ok's payload, of the type T the edge says; an err's `data`,
 * if any, is for the caller to act on ({ status } of a failed ubus call).
 *
 * @template T
 * @typedef {{ ok: boolean, data: T, error: ?string, details: ?(string|Object), none: ?string }} Result
 */

// Collectors are imported one program each, and each program gets its own copy
// of this module: a Result is known by its prototype's mark, not by identity.
const MARK = 'prometheus_exporter.result';
const ResultMethods = { [MARK]: true };

/**
 * Whether `obj` is a Result: an object whose prototype has this module's
 * mark, whichever copy of the module made it.
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
 * Nothing to observe: a collector whose subject is not there (no such hardware,
 * no such kernel feature, or its service disabled) succeeds without samples,
 * and says why in `none` ('no wireless radios', 'dnsmasq is disabled'). It is
 * ok, so whatever counts successes counts it.
 *
 * @param {?string} reason why there is nothing to observe; 'nothing there'
 *   when null. Anything else is made a string.
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
 * @param {string} error the error code, one of prometheus_exporter.errors'
 *   (or a collector's own).
 * @param {?(string|Object)} details what the log says of it; an object is a
 *   diagnostic, which describe() leaves out.
 * @param {*} data anything the caller may act on: its shape is the edge's
 *   ({ status } of a failed ubus call or program), or null.
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
