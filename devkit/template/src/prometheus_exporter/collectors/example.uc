// A collector of another package than the exporter's: the devkit's template.
// Copy the package, rename `example` everywhere (this file, its meta.name,
// its test, the Makefile's PKG_NAME), and make collect() read what yours
// does. See the exporter's "Write a collector in your own package".

'use strict';

import { Result, errors, proc } from 'prometheus_exporter.api';

// Its top level only declares: constants, functions, meta and the API's
// import. It runs again in uhttpd's own process each time the service
// starts, where nothing would stop a loop or a sleep.
const UPTIME = '/proc/uptime';
const SWAPS = '/proc/swaps';
const KIB = 1024;

/**
 * What the exporter loads, checks and lists: its name (the module's, with
 * `-` for `_`), a title and a sentence for LuCI, the capabilities it gets in
 * collect()'s deps, and its own options. It reads procfs alone, which every
 * jail has: it declares no paths.
 *
 * @type {Meta}
 */
export const meta = {
	name: 'example',
	title: 'Example: uptime and swap',
	help: 'Seconds since boot from /proc/uptime, and each swap area from /proc/swaps: the devkit\'s template.',
	needs: [ 'fs' ],
	options: {
		swaps: {
			default: true,
			title: 'Swap areas',
			help: 'Whether to write the size and use of each swap area.',
		},
	},
};

// Each swap area of /proc/swaps, a header line and then a row of its
// Filename, Type, Size and Used (in KiB) and Priority each.
function swaps(fs, out) {
	let rows = proc.rows(fs, SWAPS);

	if (rows == null)
		return Result.err(errors.SOURCE_UNREADABLE, SWAPS);

	let size = out.gauge('example_swap_size_bytes', 'Size of the swap area.');
	let used = out.gauge('example_swap_used_bytes', 'Bytes of the swap area in use.');

	for (let i = 1; i < length(rows); i++) {
		let r = rows[i];

		if (!length(r))
			continue;
		if (length(r) < 4 || !match(r[2], /^[0-9]+$/) || !match(r[3], /^[0-9]+$/))
			return Result.err(errors.SOURCE_INVALID, `${SWAPS}: line ${i + 1}: ${join(' ', r)}`);

		let labels = out.labels({ device: r[0], type: r[1] });

		size(labels, +r[2] * KIB);
		used(labels, +r[3] * KIB);
	}

	return Result.ok();
}

/**
 * Writes the seconds since boot and those the CPUs were idle, and each swap
 * area unless its option `swaps` is off. Fails with SOURCE_UNREADABLE when a
 * file cannot be read, SOURCE_INVALID when it is not what the kernel writes.
 *
 * @param {Deps} deps its capabilities: deps.fs.
 * @param {Recorder} out what it writes its families to.
 * @param {{ swaps: boolean }} options its own options, typed.
 * @returns {Result} ok, or why it failed.
 */
export function collect(deps, out, options) {
	let line = proc.first_line(deps.fs, UPTIME);

	if (line == null)
		return Result.err(errors.SOURCE_UNREADABLE, UPTIME);

	let x = proc.fields(line);

	if (length(x) < 2 || !match(x[0], /^[0-9]+(\.[0-9]+)?$/) || !match(x[1], /^[0-9]+(\.[0-9]+)?$/))
		return Result.err(errors.SOURCE_INVALID, `${UPTIME}: ${sprintf('%J', line)}`);

	// Families of one sample each, without labels.
	out.batch('counter', [
		[ 'example_uptime_seconds_total', 'Seconds since the system booted.', +x[0] ],
		[ 'example_idle_seconds_total', 'Seconds the CPUs spent idle since boot, summed.', +x[1] ],
	]);

	return options.swaps ? swaps(deps.fs, out) : Result.ok();
};
