/**
 * The collector API's exposition functions, each loaded the first time it is called; a namespace ucode keeps constant.
 *
 * @module prometheus_exporter_api_exposition
 */

'use strict';

let format = null;

function loaded(name) {
	return function(...args) {
		format ??= loadstring(
			"import { parse, format_value, sanitize } from 'prometheus.exporter.exposition';\n" +
			'return { parse, format_value, sanitize };',
			{ raw_mode: true })();

		return format[name](...args);
	};
}

/**
 * The exposition format's parse().
 *
 * @type {function(?string): Result<Family[]>}
 */
export const parse = loaded('parse');

/**
 * The exposition format's format_value().
 *
 * @type {function(*): ?string}
 */
export const format_value = loaded('format_value');

/**
 * The exposition format's sanitize().
 *
 * @type {function(*, ?boolean): string}
 */
export const sanitize = loaded('sanitize');
