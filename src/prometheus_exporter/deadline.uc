'use strict';

// A scrape's deadline: the time it has to answer, before the scraper gives up.
//
// Prometheus says how long it waits, in each request's
// X-Prometheus-Scrape-Timeout-Seconds (its scrape_timeout, 10 s unless a job
// says otherwise), and vmagent does too. Without it, the main section's
// scrape_timeout stands in. Neither may be more than uhttpd gives the handler
// (SCRIPT_TIMEOUT, its -t), after which it kills the request, answering
// nothing.
//
// A scrape stops starting collectors once its budget is spent: the timeout
// less MARGIN, which is left for what follows the last collector (merging and
// writing the reply, gzip, sending it) and for the network and the scraper
// themselves; prometheus_exporter.ledger adds what writing the reply is
// expected to cost. Times are monotonic seconds (now()).

import { SCRIPT_TIMEOUT } from 'prometheus_exporter.config';

// The request header, as uhttpd-mod-ucode names headers: in lower case.
export const HEADER = 'x-prometheus-scrape-timeout-seconds';

// The seconds the timeout keeps back, at most: as blackbox_exporter's
// --timeout-offset, whose default is the same half second, for the network
// and the scraper. What writing the reply costs is reserved apart, as it grows
// with the samples (prometheus_exporter.ledger).
export const MARGIN = 0.5;

const NUMBER = /^[0-9]+(\.[0-9]*)?$|^\.[0-9]+$/;

// A monotonic clock's [ s, ns ] as seconds.
export function seconds(t) {
	return t[0] + t[1] / 1000000000.0;
};

// The seconds a scrape may take: the header's value when it is a positive
// number, else `fallback` (scrape_timeout), and never more than uhttpd gives
// the handler.
export function timeout(value, fallback) {
	let v = (type(value) == 'string') ? trim(value) : '';
	// ucode reads '.5' as NaN.
	let t = match(v, NUMBER) ? +((substr(v, 0, 1) == '.') ? '0' + v : v) : null;

	if (t == null || t <= 0)
		t = fallback;

	return min(t, SCRIPT_TIMEOUT);
};

// The seconds the collectors may take of `timeout`: all but MARGIN, and never
// less than half of it.
export function budget(timeout) {
	return max(timeout - MARGIN, timeout / 2.0);
};
