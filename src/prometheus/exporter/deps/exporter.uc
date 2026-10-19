/**
 * The exporter capability: the exporter itself, read only, for its own collector.
 *
 * @module prometheus_exporter_deps_exporter
 */

'use strict';

/**
 * The scrape as the `exporter` capability sees it, as data that crosses a process's pipe.
 *
 * @typedef {{ pid: ?int }} ExporterView
 */

/**
 * deps.exporter: exporter_channel's object.
 *
 * @typedef {{
 *   process: (file: string) => ?string,
 *   fds: () => ?int,
 *   system: (file: string) => ?string
 * }} ExporterCapability
 */

/**
 * The files of the serving process's /proc/<pid> exporter_channel reads.
 *
 * @type {string[]}
 */
export const PROCESS_FILES = [ 'stat', 'status', 'limits' ];

/**
 * The system's files exporter_channel reads: the boot time and the auxiliary vector.
 *
 * @type {string[]}
 */
export const SYSTEM_FILES = [ '/proc/stat', '/proc/self/auxv' ];

/**
 * The exporter capability: the serving process, read only.
 *
 * @param {module:fs} fs the fs module, or an object of its readfile and lsdir.
 * @param {?ExporterView} view the scrape's, or null.
 * @returns {ExporterCapability} the capability.
 */
export function exporter_channel(fs, view) {
	let base = `/proc/${view?.pid ?? 'self'}`;

	return {
		process: (file) => (file in PROCESS_FILES) ? fs.readfile(`${base}/${file}`) : null,
		fds: function() {
			let entries = fs.lsdir(`${base}/fd`);

			return (entries == null) ? null : length(entries);
		},
		system: (file) => (file in SYSTEM_FILES) ? fs.readfile(file) : null,
	};
};
