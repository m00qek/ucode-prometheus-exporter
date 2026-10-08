'use strict';

// uhttpd for the benchmark's handler: cases (run.uc): started with a ucode
// handler as the init script starts the service's, asked for /metrics by
// busybox's wget, which every OpenWrt has (ucode's socket module is not on
// every device, nor in QEMU's guest), and stopped.

import * as fs from 'fs';

// The port it listens on, on loopback: the service's is 9100.
export const PORT = 9199;

// How long it may take to start serving: it loads, and first loads in a
// child process, every collector of the set (2 s on a 500-MIPS MIPS router).
const START_SECONDS = 120;

function now() {
	let t = clock(true);
	return t[0] + t[1] / 1000000000.0;
}

// Whether something listens on 127.0.0.1:`port`, as /proc/net/tcp says,
// without asking it for a scrape.
function listening(port) {
	let want = sprintf('0100007F:%04X', port);

	for (let line in split(fs.readfile('/proc/net/tcp') ?? '', '\n')) {
		let f = split(trim(line), /\s+/);

		// The local address, and 0A: LISTEN.
		if (f[1] == want && f[3] == '0A')
			return true;
	}

	return false;
}

// Whether the programs and the module it needs are there: uhttpd, its
// ucode plugin, and the exporter's modules where uhttpd's ucode finds them,
// the same ones the bench runs (`src`, null for the installed exporter).
export function missing(src) {
	for (let p in [ '/usr/sbin/uhttpd', '/usr/lib/uhttpd_ucode.so' ])
		if (!fs.stat(p))
			return `no ${p}`;

	let installed = fs.realpath('/usr/share/ucode/prometheus_exporter');

	if (installed == null)
		return 'the exporter is not in /usr/share/ucode, where uhttpd\'s ucode looks';
	if (src != null && installed != fs.realpath(`${src}/prometheus_exporter`))
		return `/usr/share/ucode/prometheus_exporter is not ${src}'s`;

	return null;
};

// Stops uhttpd.
export function stop(pid) {
	if (pid > 0)
		system(sprintf('kill %d 2>/dev/null', pid));
};

// { ok, pid, port, error }: uhttpd started in the background with `handler`
// on PORT, BENCH_HANDLER=`cfg` in its environment, once it serves.
export function start(handler, cfg, pidfile) {
	fs.unlink(pidfile);

	system(sprintf("BENCH_HANDLER='%s' /usr/sbin/uhttpd -f -c /dev/null -h /dev/null -S -D -k 0 -t 60 " +
		"-o /metrics -O '%s' -p 127.0.0.1:%d >/dev/null 2>&1 </dev/null & echo $! >'%s'", cfg, handler, PORT, pidfile));

	let pid = +trim(fs.readfile(pidfile) ?? '');
	let until = now() + START_SECONDS;

	while (now() < until) {
		if (listening(PORT))
			return { ok: true, pid, port: PORT };
		if (!fs.stat(`/proc/${pid}`))
			return { ok: false, error: 'uhttpd ended before it served' };
		system('sleep 0.05 2>/dev/null || sleep 1');
	}

	stop(pid);
	return { ok: false, error: `uhttpd did not serve within ${START_SECONDS} s` };
};

// { status, body }: GET `path` (/metrics), its body written to `out`. wget
// says no more of the status than whether it was 200.
export function get(port, out, path) {
	fs.unlink(out);

	let ok = system(sprintf("wget -q -O '%s' 'http://127.0.0.1:%d%s' 2>/dev/null", out, port, path ?? '/metrics')) == 0;

	return { status: ok ? '200 OK' : 'not 200', body: fs.readfile(out) ?? '' };
};

// The memory and descriptors of process `pid`: { rss_kb, fds }.
export function server(pid) {
	let m = match(fs.readfile(`/proc/${pid}/status`) ?? '', /VmRSS:\s+([0-9]+) kB/);

	return { rss_kb: m ? +m[1] : null, fds: length(fs.lsdir(`/proc/${pid}/fd`) ?? []) };
};

