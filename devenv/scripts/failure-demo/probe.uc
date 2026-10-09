'use strict';

// make failure-demo's look at an exporter from where it runs, once the
// Prometheus server is done: one scrape of 127.0.0.1:9100 with no scraper's
// timeout but uhttpd's own (60 s), given 90 s before it is given up on; how
// long it took, what it served, and which collectors it says failed. Prints a
// JSON object. HTTP/1.0 by hand, on a socket: uclient-fetch, OpenWrt's wget,
// waits on forever, whatever its -T, for a reply uhttpd ends with none.
// usage: ucode probe.uc

import * as socket from 'socket';

const LIMIT = 90;

function now() {
	let t = clock(true);

	return t[0] + t[1] / 1e9;
}

let t0 = now();
let conn = socket.connect('127.0.0.1', 9100);
let reply = '', ended = false;

if (conn) {
	conn.send('GET /metrics HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n');

	while (now() - t0 < LIMIT) {
		let ready = socket.poll(1000, [ conn, socket.POLLIN ]);

		if (!length(ready) || !ready[0][1])
			continue;

		let chunk = conn.recv(65536);

		if (chunk == null || chunk == '') {
			ended = true;
			break;
		}
		reply += chunk;
	}

	conn.close();
}

let seconds = now() - t0;
let head = split(reply, '\r\n\r\n', 2);
let status = match(head[0] ?? '', /^HTTP\/1\.[01] ([0-9]+)/);
let samples = 0, collectors = 0, failed = [];

for (let line in split(head[1] ?? '', '\n')) {
	if (line == '' || substr(line, 0, 1) == '#')
		continue;
	samples++;

	let f = match(line, /^node_scrape_collector_success\{collector="([^"]+)"\} ([01])$/);

	if (f)
		collectors++;
	if (f && f[2] == '0')
		push(failed, f[1]);
}

print(sprintf('%J\n', {
	seconds: int(seconds * 100) / 100.0,
	status: status ? +status[1] : null,
	ended,
	samples,
	collectors,
	failed: sort(failed),
}));
