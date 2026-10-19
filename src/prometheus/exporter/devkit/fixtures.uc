/**
 * The devkit's fixtures: what a device answered, captured to files, for the mocks.
 *
 * @module prometheus_exporter_devkit_fixtures
 */

'use strict';

const real_fs = require('fs');

/**
 * What a reader of a fixtures directory reads: files, as an fs mock's data, ubus replies.
 *
 * @typedef {{
 *   file: function(string): string,
 *   files: function(string[]): Object<string, string>,
 *   ubus: function(string, string): *
 * }} FixtureReader
 */

/**
 * A reader of the fixtures under `dir`, relative to utest's directory or absolute.
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
