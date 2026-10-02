'use strict';

// The exporter itself: the process that serves the scrapes, as Prometheus's
// client libraries describe a process (process_*), and what went wrong in its
// scrapes, as the ledger counts it (prometheus_exporter.ledger).
//
// The process is the uhttpd instance that loaded the handler: each scrape is
// a process forked from it, which uhttpd reaps when it has answered, so the
// instance's children's times (/proc/<pid>/stat's cutime and cstime) are
// every scrape's, and process_cpu_seconds_total is all the CPU the exporter
// costs. Run elsewhere (the command line, check), it is that process.
//
// The counters are the instance's, kept in its state, and so start again at 0
// when the service restarts, as a new process's would. Where there is no
// ledger (the command line, check, the ubus object), they are left out.
// ucode_prometheus_exporter_collector_samples is this scrape's: the samples
// each collector wrote, which shows one whose series grow without end. This
// collector runs after every other, so it sees them all.
//
// It does not repeat what Prometheus knows of the scrape itself
// (scrape_duration_seconds, scrape_samples_scraped).

import { Result, errors, proc } from 'prometheus_exporter.api';

export const meta = {
	name: 'exporter',
	title: 'The exporter itself',
	help: 'The CPU, memory and descriptors of the uhttpd instance that serves the scrapes, its scrapes, and what went wrong in them: failures, programs killed, quarantines, collectors left out at the deadline.',
	needs: [ 'exporter' ],
};

// Linux's USER_HZ on every architecture OpenWrt builds for, for a vector that
// does not say.
export const CLOCK_TICKS = 100;

const BTIME = /(^|\n)btime ([0-9]+)/;
const VMRSS = /(^|\n)VmRSS:\s+([0-9]+) kB/;
const MAX_FILES = /(^|\n)Max open files\s+([0-9]+|unlimited)\s/;

// The fields of /proc/<pid>/stat after the command, from the 3rd: { cpu (in
// ticks: user, system, and the children's), start (ticks after boot),
// vsize (bytes) }, or null.
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

function number_of(text, re) {
	let m = (type(text) == 'string') ? match(text, re) : null;

	return m ? m[2] : null;
}

function process(deps, out) {
	let ex = deps.exporter;
	let stat = parse_stat(ex.process('stat'));

	if (stat == null)
		return Result.err(errors.SOURCE_UNREADABLE, 'the serving process\'s /proc/<pid>/stat');

	let tick = proc.auxv(ex.system('/proc/self/auxv'))?.[proc.AT_CLKTCK] || CLOCK_TICKS;
	let btime = number_of(ex.system('/proc/stat'), BTIME);
	let rss = number_of(ex.process('status'), VMRSS);
	let max_fds = number_of(ex.process('limits'), MAX_FILES);
	let fds = ex.fds();

	out.counter('process_cpu_seconds_total', 'Total user and system CPU time spent in seconds, the scrapes it answered in processes of their own included.')(null, stat.cpu / (tick * 1.0));
	out.gauge('process_virtual_memory_bytes', 'Virtual memory size in bytes.')(null, stat.vsize);
	if (rss != null)
		out.gauge('process_resident_memory_bytes', 'Resident memory size in bytes.')(null, +rss * 1024);
	if (btime != null)
		out.gauge('process_start_time_seconds', 'Start time of the process since unix epoch in seconds.')(null, +btime + stat.start / (tick * 1.0));
	if (fds != null)
		out.gauge('process_open_fds', 'Number of open file descriptors.')(null, fds);
	if (max_fds != null && max_fds != 'unlimited')
		out.gauge('process_max_fds', 'Maximum number of open file descriptors.')(null, +max_fds);

	return Result.ok();
}

function counters(n, out) {
	out.counter('ucode_prometheus_exporter_scrapes_total', 'Scrapes the exporter answered since the service started.')(null, n.scrapes);
	out.counter('ucode_prometheus_exporter_auth_failures_total', 'Requests basic auth refused since the service started.')(null, n.auth_failures);

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
