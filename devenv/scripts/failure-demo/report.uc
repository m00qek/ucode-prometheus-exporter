'use strict';

// make failure-demo's report: what a Prometheus server that scraped the
// demo's targets got from each, read from its HTTP API: every scrape's `up`,
// `scrape_duration_seconds` and `scrape_samples_scraped`, the target's last
// error, the collectors that failed in the last scrape it got
// (node_scrape_collector_success 0), and those this exporter quarantined.
// Each target is labeled with its `scenario` and `exporter`. Prints a JSON
// array, one object a target, in the order of the targets' scenarios as
// given, ours first.
// usage: ucode report.uc PROMETHEUS_URL SCENARIO...

import { popen } from 'fs';

const base = ARGV[0];
const order = slice(ARGV, 1);

function encode(s) {
	return replace(s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf('%%%02X', ord(c)));
}

function get(path) {
	let p = popen(`wget -q -T 30 -O - '${base}${path}'`);
	let body = p.read('all');

	p.close();

	let reply = json(body ?? 'null');

	if (reply?.status != 'success')
		die(`report.uc: ${path}: ${body}\n`);

	return reply.data;
}

function query(q) {
	return get(`/api/v1/query?query=${encode(q)}`).result;
}

function key(metric) {
	return `${metric.scenario}/${metric.exporter}`;
}

// The raw samples of `name` over the whole run, by target, oldest first.
function series(name) {
	let out = {};

	for (let r in query(`${name}[1h]`))
		out[key(r.metric)] = map(r.values, (v) => +v[1]);

	return out;
}

const ups = series('up');
const durations = series('scrape_duration_seconds');
const samples = series('scrape_samples_scraped');
const failed = {};
const quarantined = {};

for (let r in query('last_over_time(node_scrape_collector_success[1h]) == 0'))
	push(failed[key(r.metric)] ??= [], r.metric.collector);
for (let r in query('max_over_time(ucode_prometheus_exporter_collector_quarantined[1h]) == 1'))
	push(quarantined[key(r.metric)] ??= [], r.metric.collector);

let out = [];

for (let t in get('/api/v1/targets?state=active').activeTargets) {
	let k = key(t.labels);

	push(out, {
		scenario: t.labels.scenario,
		exporter: t.labels.exporter,
		up: ups[k] ?? [],
		duration: durations[k] ?? [],
		samples: samples[k] ?? [],
		last_error: t.lastError,
		failed: sort(failed[k] ?? []),
		quarantined: sort(quarantined[k] ?? []),
	});
}

function rank(t) {
	let i = index(order, t.scenario);

	return (i < 0 ? length(order) : i) * 2 + (t.exporter == 'ours' ? 0 : 1);
}

print(sprintf('%.2J\n', sort(out, (a, b) => rank(a) - rank(b))));
