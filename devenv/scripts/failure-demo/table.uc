'use strict';

// make failure-demo's tables, in Markdown: what Prometheus got from each
// target (report.uc's JSON), and what each exporter says of itself: in the
// last scrape Prometheus got, in its log (DIR/<scenario>-<exporter>.log), and
// in one scrape without a scraper's timeout at the end (probe.uc's JSON,
// DIR/<scenario>-<exporter>.probe.json).
// usage: ucode table.uc DIR REPORT.json...

import { readfile } from 'fs';

const dir = ARGV[0];
let targets = [];

for (let path in slice(ARGV, 1))
	push(targets, ...json(readfile(path)));

function seconds(v) {
	return sprintf(v < 10 ? '%.2f s' : '%.1f s', v);
}

function range(values, fmt) {
	let lo = min(...values), hi = max(...values);

	return lo == hi ? fmt(lo) : `${fmt(lo)} to ${fmt(hi)}`;
}

function durations(d) {
	if (!length(d))
		return '—';
	if (length(d) == 1)
		return seconds(d[0]);

	return `first ${seconds(d[0])}, then ${range(slice(d, 1), seconds)}`;
}

function cell(s) {
	return replace(s, '|', '\\|');
}

function list(items) {
	return length(items) ? join(', ', items) : 'none';
}

// What the log says went wrong, once each: this exporter's error codes by
// collector and the most collectors a deadline left out; the Lua exporter's
// errors, as its collectors raised them.
function log_of(t) {
	let text = readfile(`${dir}/${t.scenario}-${t.exporter}.log`) ?? '';
	let seen = {}, out = [], most = 0;

	for (let line in split(text, '\n')) {
		let m = match(line, /collector '([^']+)'(:| quarantined)[^A-Z]*([A-Z_]+) /)
			?? match(line, /prometheus-collectors\/([A-Za-z0-9_-]+)\.lua:[0-9]+: (.*)$()/);
		let d = match(line, /scrape deadline: ([0-9]+) collectors not served/);

		if (d)
			most = max(most, +d[1]);
		if (!m)
			continue;

		let what = m[3] ? `${m[1]} ${m[3]}` : `${m[1]}: ${substr(m[2], 0, 50)}`;

		if (m[2] == ' quarantined')
			what = `${m[1]} quarantined`;
		if (!seen[what]) {
			seen[what] = true;
			push(out, what);
		}
	}

	if (most)
		push(out, `up to ${most} collectors left out at the deadline`);

	return list(out);
}

function direct(p) {
	if (!p)
		return '—';
	if (!p.ended)
		return `no reply in ${seconds(p.seconds)}`;
	if (p.status != 200)
		return `closed after ${seconds(p.seconds)}, ${p.status ? `status ${p.status}` : 'no reply'}`;

	return `${seconds(p.seconds)}, ${p.samples} samples, ${p.collectors} collectors, failed: ${list(p.failed)}`;
}

print('What a Prometheus server scraping each exporter every 15 s, with its default 10 s timeout, got:\n\n');
print('| Scenario | Exporter | Scrapes up | Scrape duration | Samples | Prometheus\'s last error |\n');
print('| :--- | :--- | :--- | :--- | :--- | :--- |\n');

for (let t in targets) {
	let up = length(filter(t.up, (v) => v == 1));

	print(`| ${t.scenario} | ${t.exporter} | ${up} of ${length(t.up)} | ${durations(t.duration)} | ` +
		`${length(t.samples) ? range(t.samples, (v) => `${v}`) : '—'} | ` +
		`${cell(t.last_error ? replace(t.last_error, /^Get "[^"]*": /, '') : '—')} |\n`);
}

print('\nWhat each exporter says: the collectors that failed in the last scrape Prometheus got ' +
	'(node_scrape_collector_success 0), and those this exporter quarantined; what its log says; and one scrape ' +
	'at the end, from where it runs, with no timeout but uhttpd\'s:\n\n');
print('| Scenario | Exporter | Failed, last scrape | Quarantined | The log | A scrape without a timeout |\n');
print('| :--- | :--- | :--- | :--- | :--- | :--- |\n');

for (let t in targets) {
	let p = json(readfile(`${dir}/${t.scenario}-${t.exporter}.probe.json`) ?? 'null');
	let got = length(filter(t.up, (v) => v == 1));

	print(`| ${t.scenario} | ${t.exporter} | ${got ? list(t.failed) : '— (no scrape)'} | ` +
		`${t.exporter == 'ours' ? list(t.quarantined) : '—'} | ${cell(log_of(t))} | ${cell(direct(p))} |\n`);
}
