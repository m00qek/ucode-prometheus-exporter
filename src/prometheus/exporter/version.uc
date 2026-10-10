/**
 * The exporter's version: the package's, or 'dev' in a source tree.
 *
 * @module prometheus_exporter_version
 */

'use strict';

const VERSION = 'dev';

/**
 * The exporter's version.
 *
 * @returns {string}
 */
export function version() {
	return VERSION;
};
