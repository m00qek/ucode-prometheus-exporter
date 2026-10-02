'use strict';

// Runs of the collectors outside the service, in the service's own jail: the
// command line's scrape, check's and the ubus object's status. They run
// trial.uc (TRIAL) under ujail, with what the init script has procd mount for
// the service (prometheus_exporter.jail's mounts of the enabled collectors, the
// exporter's code and libraries, the state read-write), procfs, sysfs, the log
// and ubus, at the service's priority and memory limit: so what they find is
// what Prometheus gets. The collectors run in it as in the service, each in a
// process of its own (prometheus_exporter.runner).
//
// ujail needs root and a kernel that lets it make namespaces: where it is not
// there, or fails, the caller runs them in its own process, outside the jail,
// with the same guards, and says so.
//
// ujail writes its own lines on standard output, each starting `jail: `,
// before and after what it runs: output() leaves them out.
//
// sys: { uci: a cursor, fs: { stat, glob, readfile, popen }, path: the PATH
//        commands are found on }

import * as config from 'prometheus_exporter.config';
import * as jail from 'prometheus_exporter.jail';
import { shell_quote } from 'prometheus_exporter.deps';
import { DIR as STATE_DIR } from 'prometheus_exporter.state';

export const UJAIL = '/sbin/ujail';
export const UCODE = '/usr/bin/ucode';
export const TRIAL = `/usr/libexec/${config.NAME}/trial.uc`;

// What the init script mounts of the exporter itself: its code, and the
// libraries of ucode's modules. ujail stages the libraries each library it
// is given needs, but not those of a directory: each module's own.
export const CODE = [ '/usr/share/ucode/prometheus_exporter', TRIAL ];
export const LIBS = [ '/usr/lib/ucode/*.so', '/lib/libubus.so*', '/lib/libuci.so*', '/usr/lib/libnl*.so*', '/usr/lib/libz.so*' ];

// The service's priority (the init script's nice).
export const NICE = 10;

// Whether ujail is there, and this process can run it: root's.
export function available(fs) {
	let uid = match(fs.readfile('/proc/self/status') ?? '', /\nUid:\s+([0-9]+)/);

	return fs.stat(UJAIL)?.type == 'file' && uid?.[1] == '0';
};

// The kB of data each process may take, as the init script sets it.
export function data_kb(sys) {
	let svc = config.service_values(sys.uci);
	let mb = svc.ok ? svc.data.memory_limit : 0;
	let total = match(sys.fs.readfile('/proc/meminfo') ?? '', /MemTotal:\s+([0-9]+) kB/);

	return config.memory_limit_mb(mb, total ? +total[1] : 0) * 1024;
};

// The shell command that runs trial.uc with `args` in the service's jail, for
// the installed `collectors`.
export function command(sys, collectors, args) {
	let ro = [ ...jail.mounts(collectors, sys).mounts, ...CODE ];

	for (let pattern in LIBS)
		push(ro, ...(sys.fs.glob(pattern) ?? []));

	return sprintf('ulimit -d %d && exec nice -n %d %s -n %s -p -s -l -u %s -w %s -- %s %s %s 2>/dev/null',
		data_kb(sys), NICE, UJAIL, shell_quote(`${config.NAME}-trial`),
		join(' ', map(uniq(ro), (p) => '-r ' + shell_quote(p))), shell_quote(STATE_DIR),
		UCODE, TRIAL, join(' ', map(args, shell_quote)));
};

// What trial.uc printed, as JSON, less ujail's own lines; null when it
// printed none.
export function output(text) {
	let lines = filter(split(text ?? '', '\n'), (l) => substr(l, 0, 6) != 'jail: ' && l != '');
	let out = null;

	try {
		out = json(join('\n', lines));
	} catch (e) {
		out = null;
	}

	return (type(out) == 'object') ? out : null;
};

// trial.uc's reply to `args`, run in the service's jail, or null when it
// could not be: no ujail, not root, or no reply.
export function run(sys, collectors, args) {
	if (!available(sys.fs))
		return null;

	let p = sys.fs.popen(command(sys, collectors, args), 'r');

	if (!p)
		return null;

	let text = p.read('all');

	p.close();
	return output(text);
};

// A run of each of the `chosen` collectors, as trial.uc runs them in the
// jail: { jailed, runs }, the runs in the order of `chosen`, each
// { name, id, result, duration, samples } (result plain, without its
// prototype); one the jail did not load is not run there. Where the jail
// cannot be had, jailed is false and the runs are fallback()'s.
export function trial(sys, collectors, chosen, fallback) {
	let out = run(sys, collectors, [ 'runs' ]);

	if (type(out?.runs) != 'array')
		return { jailed: false, runs: fallback() };

	let by_id = {};

	for (let r in out.runs)
		by_id[r.id] = r;

	return {
		jailed: true,
		runs: map(chosen, (c) => by_id[c.id] ?? {
			name: c.meta.name, id: c.id, duration: 0, samples: 0,
			result: { ok: false, error: 'COLLECTOR_INVALID', details: 'not loaded in the jail' },
		}),
	};
};
