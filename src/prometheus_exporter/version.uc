/**
 * The exporter's version, as ucode_prometheus_exporter_build_info reports it:
 * the package's (PKG_VERSION-rPKG_RELEASE), which the package Makefile writes
 * over 'dev' when it installs this file. 'dev' is a source tree's.
 *
 * @module prometheus_exporter_version
 */

'use strict';

const VERSION = 'dev';

/**
 * The exporter's version.
 *
 * @returns {string} PKG_VERSION-rPKG_RELEASE when installed, 'dev' in a
 *   source tree.
 */
export function version() {
	return VERSION;
};
