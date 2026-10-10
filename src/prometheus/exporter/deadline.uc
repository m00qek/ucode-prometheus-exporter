/**
 * A scrape's deadline: the time it has to answer, before the scraper gives up.
 *
 * @module prometheus_exporter_deadline
 */

'use strict';

import { SCRIPT_TIMEOUT } from 'prometheus.exporter.config';

/** The request header, as uhttpd-mod-ucode names headers: in lower case. */
export const HEADER = 'x-prometheus-scrape-timeout-seconds';

/** The seconds the timeout keeps back, at most, for the network and the scraper. */
export const MARGIN = 0.5;

const NUMBER = /^[0-9]+(\.[0-9]*)?$|^\.[0-9]+$/;

/**
 * A monotonic clock's [ s, ns ] as seconds.
 *
 * @param {int[]} t
 * @returns {float}
 */
export function seconds(t) {
	return t[0] + t[1] / 1000000000.0;
};

/**
 * The seconds a scrape may take, never more than uhttpd gives the handler.
 *
 * @param {?string} value
 * @param {(int|float)} fallback
 * @returns {(int|float)}
 */
export function timeout(value, fallback) {
	let v = (type(value) == 'string') ? trim(value) : '';
	let t = match(v, NUMBER) ? +((substr(v, 0, 1) == '.') ? '0' + v : v) : null;

	if (t == null || t <= 0)
		t = fallback;

	return min(t, SCRIPT_TIMEOUT);
};

/**
 * The seconds the collectors may take of `timeout`: all but MARGIN, and never less than half of it.
 *
 * @param {(int|float)} timeout
 * @returns {float}
 */
export function budget(timeout) {
	return max(timeout - MARGIN, timeout / 2.0);
};
