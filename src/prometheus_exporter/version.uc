'use strict';

// The exporter's version, as ucode_prometheus_exporter_build_info reports it:
// the package's (PKG_VERSION-rPKG_RELEASE), which the package Makefile writes
// over 'dev' when it installs this file. 'dev' is a source tree's.

const VERSION = 'dev';

export function version() {
	return VERSION;
};
