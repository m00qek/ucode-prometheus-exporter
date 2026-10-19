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
 * @returns {string} PKG_VERSION-rPKG_RELEASE when installed, 'dev' in a source tree.
 */
export function version() {
	return VERSION;
};
