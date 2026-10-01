'use strict';

// ok/err Result for fallible edges (the pattern of wgpathd and luci-sso).

// Collectors are imported one program each, and each program gets its own copy
// of this module: a Result is known by its prototype's mark, not by identity.
const MARK = 'prometheus_exporter.result';
const ResultMethods = { [MARK]: true };

export function is(obj) {
	return type(obj) == 'object' && proto(obj)?.[MARK] === true;
};

export function ok(data) {
	return proto({ ok: true, data: data }, ResultMethods);
};

// `details` is for the log; `data`, if any, for the caller to act on.
export function err(error, details, data) {
	return proto({ ok: false, error: error, details: details, data: data }, ResultMethods);
};

// Only string details are shown: object details are diagnostics, not log text.
export function describe(res) {
	return (type(res.details) == 'string' && length(res.details) > 0)
		? `${res.error} (${res.details})`
		: `${res.error}`;
};
