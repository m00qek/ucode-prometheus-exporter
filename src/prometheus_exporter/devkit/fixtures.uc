/**
 * The devkit's fixtures: what a device answered, captured to files under a
 * directory of a collector package's tests, read for the mocks of
 * with_collector (prometheus_exporter.devkit.collector). Files keep their
 * own paths under it, `<dir>/proc/loadavg` for /proc/loadavg, and ubus
 * replies are `<dir>/ubus/<object>.<method>.json`, as `ubus call <object>
 * <method>` prints them.
 *
 *   const DEVICE = fixtures.reader(sourcepath(0, true) + '/fixtures/my-router');
 *   with_collector(mine, { fs: { data: DEVICE.files([ '/proc/loadavg' ]) } }, ...)
 *
 * They are read with the real fs, whatever mock is patched in. A fixture
 * that is not there fails the test that reads it, naming it.
 *
 * What it exports is what a major version of the exporter protects.
 *
 * @module prometheus_exporter_devkit_fixtures
 */

'use strict';

// The real fs: under utest, an import of fs reaches whatever mock is patched in.
const real_fs = require('fs');

/**
 * What a reader of a fixtures directory reads: a file's text by the path it
 * has on the device, several as an fs mock's data, and a ubus reply.
 *
 * @typedef {{
 *   file: function(string): string,
 *   files: function(string[]): Object<string, string>,
 *   ubus: function(string, string): *
 * }} FixtureReader
 */

/**
 * A reader of the fixtures under `dir`, a directory relative to the one
 * utest runs in, or absolute (sourcepath(0, true) gives a test's own).
 *
 * @param {string} dir the fixtures' directory.
 * @returns {FixtureReader} the reader.
 */
export function reader(dir) {
	function file(path) {
		let s = real_fs.readfile(`${dir}${path}`);

		if (s == null)
			die(`no fixture ${dir}${path}: capture it from a device, at that path under ${dir}`);

		return s;
	}

	return {
		file,

		files: function(paths) {
			let data = {};

			for (let path in paths)
				data[path] = file(path);

			return data;
		},

		ubus: (object, method) => json(file(`/ubus/${object}.${method}.json`)),
	};
};
