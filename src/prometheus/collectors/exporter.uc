'use strict';

import { Result, errors, proc } from 'prometheus.exporter';

export const meta = {
	name: 'exporter',
	title: 'The exporter itself',
	help: 'The CPU, memory and descriptors of the uhttpd instance that serves the scrapes, its scrapes, and what went wrong in them: failures, programs killed, quarantines, collectors left out at the deadline.',
	needs: [ 'exporter' ],
};

export const CLOCK_TICKS = 100;

const BTIME = /(^|\n)btime ([0-9]+)/;
const VMRSS = /(^|\n)VmRSS:\s+([0-9]+) kB/;
const MAX_FILES = /(^|\n)Max open files\s+([0-9]+|unlimited)\s/;

const BTIME_REST = /^ ([0-9]+)/;
const VMRSS_REST = /^\s+([0-9]+) kB/;
const MAX_FILES_REST = /^\s+([0-9]+|unlimited)\s/;

export function parse_stat(text) {
	let close = (type(text) == 'string') ? rindex(text, ')') : -1;

	if (close < 0)
		return null;

	let f = split(trim(substr(text, close + 2)), ' ');
	let n = map(f, (v) => +v);

	if (length(f) < 21 || length(filter(slice(n, 11, 15), (v) => v != v)) || n[19] != n[19] || n[20] != n[20])
		return null;

	return { cpu: n[11] + n[12] + n[13] + n[14], start: n[19], vsize: n[20] };
};

function number_of(text, name, rest, re) {
	if (type(text) != 'string')
		return null;

	let i = (substr(text, 0, length(name)) == name) ? 0 : index(text, '\n' + name);
	let m = (i < 0) ? null : match(substr(text, i + ((i > 0) ? 1 : 0) + length(name), 64), rest);

	if (m)
		return m[1];
	if (i < 0)
		return null;

	m = match(text, re);

	return m ? m[2] : null;
}

function process(deps, out) {
	let ex = deps.exporter;
	let stat = parse_stat(ex.process('stat'));

	if (stat == null)
		return Result.err(errors.SOURCE_UNREADABLE, 'the serving process\'s /proc/<pid>/stat');

	let tick = proc.auxv(ex.system('/proc/self/auxv'))?.[proc.AT_CLKTCK] || CLOCK_TICKS;
	let btime = number_of(ex.system('/proc/stat'), 'btime', BTIME_REST, BTIME);
	let rss = number_of(ex.process('status'), 'VmRSS:', VMRSS_REST, VMRSS);
	let max_fds = number_of(ex.process('limits'), 'Max open files', MAX_FILES_REST, MAX_FILES);
	let fds = ex.fds();

	out.batch('counter', [
		[ 'process_cpu_seconds_total', 'Total user and system CPU time spent in seconds, the scrapes it answered in processes of their own included.', stat.cpu / (tick * 1.0) ],
	]);
	out.batch('gauge', [
		[ 'process_virtual_memory_bytes', 'Virtual memory size in bytes.', stat.vsize ],
		[ 'process_resident_memory_bytes', 'Resident memory size in bytes.', (rss != null) ? +rss * 1024 : null ],
		[ 'process_start_time_seconds', 'Start time of the process since unix epoch in seconds.', (btime != null) ? +btime + stat.start / (tick * 1.0) : null ],
		[ 'process_open_fds', 'Number of open file descriptors.', fds ],
		[ 'process_max_fds', 'Maximum number of open file descriptors.', (max_fds != 'unlimited') ? max_fds : null ],
	]);

	return Result.ok();
}

function counters(n, out) {
	out.batch('counter', [
		[ 'ucode_prometheus_exporter_scrapes_total', 'Scrapes the exporter answered since the service started.', n.scrapes ],
		[ 'ucode_prometheus_exporter_auth_failures_total', 'Requests basic auth refused since the service started.', n.auth_failures ],
	]);

	let failures = out.counter('ucode_prometheus_exporter_collector_failures_total', 'Scrapes in which a collector failed, by its error code, since the service started.');
	let timeouts = out.counter('ucode_prometheus_exporter_program_timeouts_total', 'Programs of a collector killed at their timeout since the service started.');
	let quarantines = out.counter('ucode_prometheus_exporter_quarantines_total', 'Times a collector\'s circuit breaker tripped since the service started.');
	let skips = out.counter('ucode_prometheus_exporter_deadline_skips_total', 'Scrapes whose deadline left a collector out, or killed its program, since the service started.');

	for (let name in sort(keys(n.collectors))) {
		let c = n.collectors[name];
		let labels = out.labels({ collector: name });

		for (let code in sort(keys(c.failures)))
			failures({ collector: name, reason: code }, c.failures[code]);
		timeouts(labels, c.timeouts);
		quarantines(labels, c.quarantines);
		skips(labels, c.deadline_skips);
	}
}

export function collect(deps, out) {
	let res = process(deps, out);
	let n = deps.exporter.counters();

	if (n != null)
		counters(n, out);

	let samples = deps.exporter.samples();
	let written = out.gauge('ucode_prometheus_exporter_collector_samples', 'Samples a collector wrote in this scrape.');

	for (let name in sort(keys(samples)))
		written({ collector: name }, samples[name]);

	return res;
};
