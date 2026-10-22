/**
 * Runs of the collectors outside the service, in the service's own jail.
 *
 * @module prometheus_exporter_jailed
 */

'use strict';

import * as config from 'prometheus.exporter.config';
import * as jail from 'prometheus.exporter.jail';
import { shell_quote } from 'prometheus.exporter.deps';
import { DIR as STATE_DIR } from 'prometheus.exporter.state';
import * as privileges from 'prometheus.exporter.privileges';

/**
 * A run of the chosen collectors, as trial() gives it: whether it was jailed, and the runs.
 *
 * @typedef {{ jailed: boolean, runs: Run[] }} Trial
 */

/**
 * procd's ujail.
 *
 * @type {string}
 */
export const UJAIL = '/sbin/ujail';

/**
 * The ucode interpreter, which runs trial.uc in the jail.
 *
 * @type {string}
 */
export const UCODE = '/usr/bin/ucode';

/**
 * The program that runs the collectors in the jail.
 *
 * @type {string}
 */
export const TRIAL = `/usr/libexec/${config.NAME}/trial.uc`;

/**
 * Its code: the exporter's modules, and trial.uc.
 *
 * @type {string[]}
 */
export const CODE = [ '/usr/share/ucode/prometheus', TRIAL ];

/**
 * The libraries of ucode's modules, as globs.
 *
 * @type {string[]}
 */
export const LIBS = [ '/usr/lib/ucode/*.so', '/lib/libubus.so*', '/lib/libuci.so*', '/usr/lib/libnl*.so*', '/usr/lib/libz.so*' ];

/**
 * The service's priority (the init script's nice).
 *
 * @type {int}
 */
export const NICE = 10;

/**
 * Whether ujail is there, and this process can run it: root's.
 *
 * @param {module:fs} fs what looks: an object of fs's readfile and stat.
 * @returns {boolean} whether it can.
 */
export function available(fs) {
	let uid = match(fs.readfile('/proc/self/status') ?? '', /\nUid:\s+([0-9]+)/);

	return fs.stat(UJAIL)?.type == 'file' && uid?.[1] == '0';
};

/**
 * The kB of data each process may take, as the init script sets it.
 *
 * @param {JailSys} sys the system.
 * @returns {int} the kB.
 */
export function data_kb(sys) {
	let svc = config.service_values(sys.uci);
	let mb = svc.ok ? svc.data.memory_limit : 0;
	let total = match(sys.fs.readfile('/proc/meminfo') ?? '', /MemTotal:\s+([0-9]+) kB/);

	return config.memory_limit_mb(mb, total ? +total[1] : 0) * 1024;
};

/**
 * The shell command that runs trial.uc with `args` in the service's jail.
 *
 * @param {JailSys} sys the system.
 * @param {Collector[]} collectors the installed collectors.
 * @param {string[]} args trial.uc's arguments.
 * @returns {string} the command.
 */
export function command(sys, collectors, args) {
	let mounts = jail.mounts(collectors, sys).mounts;
	let ro = [ ...filter(mounts, (p) => p != jail.UBUS_SOCKET), ...CODE ];

	for (let pattern in LIBS)
		push(ro, ...(sys.fs.glob(pattern) ?? []));

	let caps = (sys.fs.stat(privileges.CAPABILITIES_FILE) != null) ? ` -C ${shell_quote(privileges.CAPABILITIES_FILE)}` : '';

	return sprintf('ulimit -d %d && exec nice -n %d %s -n %s -U %s -G %s%s -c -p -s -l%s %s -w %s -- %s %s %s 2>/dev/null',
		data_kb(sys), NICE, UJAIL, shell_quote(`${config.NAME}-trial`), shell_quote(privileges.USER), shell_quote(privileges.GROUP), caps,
		(jail.UBUS_SOCKET in mounts) ? ` -w ${shell_quote(jail.UBUS_DIR)}` : '',
		join(' ', map(uniq(ro), (p) => '-r ' + shell_quote(p))), shell_quote(STATE_DIR),
		UCODE, TRIAL, join(' ', map(args, shell_quote)));
};

/**
 * What trial.uc printed, as JSON, less ujail's own lines; null when it printed none.
 *
 * @param {?string} text what ujail and trial.uc printed.
 * @returns {?Object} the JSON object.
 */
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

/**
 * trial.uc's reply to `args`, run in the service's jail, or null when it could not be.
 *
 * @param {JailSys} sys the system.
 * @param {Collector[]} collectors the installed collectors.
 * @param {string[]} args trial.uc's arguments.
 * @returns {?Object} trial.uc's reply.
 */
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

/**
 * A run of each of the `chosen` collectors in the service's jail, or fallback()'s.
 *
 * @param {JailSys} sys the system.
 * @param {Collector[]} collectors the installed collectors.
 * @param {Collector[]} chosen the collectors to run.
 * @param {function(): Run[]} fallback the runs where the jail cannot be had.
 * @returns {Trial} the runs.
 */
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
