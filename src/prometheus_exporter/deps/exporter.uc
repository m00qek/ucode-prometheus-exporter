/**
 * The exporter capability: the exporter itself, read only, for its own
 * collector.
 *
 * @module prometheus_exporter_deps_exporter
 */

'use strict';

/**
 * The scrape as a collector that needs `exporter` sees it, as data that
 * crosses a process's pipe: the serving process's pid (null for this one),
 * the ledger's counters of the scrapes with this one's runs so far (null
 * where there is no ledger), and { collector name: samples } of this
 * scrape's collectors so far.
 *
 * @typedef {{ pid: ?int, counters: ?LedgerCounters, samples: Object<string, int> }} ExporterView
 */

/**
 * deps.exporter: exporter_channel's object.
 *
 * @typedef {{
 *   process: (file: string) => ?string,
 *   fds: () => ?int,
 *   system: (file: string) => ?string,
 *   counters: () => ?LedgerCounters,
 *   samples: () => Object<string, int>
 * }} ExporterCapability
 */

/**
 * The files of the serving process's /proc/<pid> exporter_channel reads.
 *
 * @type {string[]}
 */
export const PROCESS_FILES = [ 'stat', 'status', 'limits' ];

/**
 * The system's files exporter_channel reads: the boot time, and the
 * auxiliary vector (the clock tick and the page size).
 *
 * @type {string[]}
 */
export const SYSTEM_FILES = [ '/proc/stat', '/proc/self/auxv' ];

/**
 * The exporter itself, read only, for its own collector: the process that
 * serves the scrapes and the counters of its scrapes, and nothing else.
 *   process(file)  /proc/<pid>/<file> of the serving process, for a file
 *                  of PROCESS_FILES; null for any other
 *   fds()          how many descriptors it has open, or null
 *   system(file)   a file of SYSTEM_FILES, or null for any other
 *   counters()     ledger.counters of its scrapes, this one's so far
 *                  included, or null where there is no ledger
 *   samples()      { collector: samples } of this scrape's collectors so far
 * `view` is the scrape's, as data that crosses a process's pipe: { pid,
 * counters, samples }; without it, the process is this one and there are no
 * counters.
 *
 * @param {module:fs} fs what reads the files: the fs module, or an object of
 *   its readfile and lsdir.
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
		counters: () => view?.counters ?? null,
		samples: () => view?.samples ?? {},
	};
};
