/**
 * Has ubusd read its ACLs again, and brings back what a crash of it leaves off ubus.
 *
 * @module prometheus_exporter_ubusd
 */

'use strict';

/**
 * The milliseconds ubusd is given to read its ACLs: it reads them at once, or crashes doing it.
 *
 * @type {int}
 */
export const SETTLE_MS = 300;

/**
 * The seconds procd is given to start ubusd again after a crash, and the services restarted to register again.
 *
 * @type {int}
 */
export const RETURN_SECONDS = 10;

/**
 * procd's object: the services restart through it, once procd has registered it on the ubusd started again.
 *
 * @type {string}
 */
export const PROCD = 'service';

/**
 * The services that do not register on ubus again when ubusd starts again, by an object each registers.
 *
 * @type {Object<string, string>}
 */
export const REREGISTER = { session: 'rpcd', dnsmasq: 'dnsmasq', dhcp: 'odhcpd' };

/**
 * What reload() acts on.
 *
 * @typedef {{
 *   ubusd_pid: function(): ?int,
 *   alive: function(int): boolean,
 *   signal: function(int): boolean,
 *   objects: function(): ?string[],
 *   restart: function(string): boolean,
 *   sleep: function(int): void
 * }} UbusdSys
 */

function wait_for(sys, done) {
	for (let waited = 0; waited < RETURN_SECONDS * 1000; waited += 500) {
		if (done())
			return true;
		sys.sleep(500);
	}

	return done();
}

/**
 * Has ubusd read its ACLs again (SIGHUP); when that crashed it, waits for procd to start it again and register on it, and restarts the services of REREGISTER whose objects it lost.
 *
 * @param {UbusdSys} sys the system.
 * @returns {{ ok: boolean, made: string[], problems: string[] }} ok when ubusd reads the ACLs and every object on ubus before is there after; the crash, and what is still missing, among the problems.
 */
export function reload(sys) {
	let pid = sys.ubusd_pid();

	if (pid == null)
		return { ok: false, made: [], problems: [ 'ubusd is not running' ] };

	let before = sys.objects() ?? [];

	if (!sys.signal(pid))
		return { ok: false, made: [], problems: [ `cannot signal ubusd (pid ${pid})` ] };

	sys.sleep(SETTLE_MS);

	if (sys.alive(pid))
		return { ok: true, made: [], problems: [] };

	let made = [];
	let problems = [ `ubusd (pid ${pid}) crashed as it read its ACLs again, and procd starts it again` ];
	let objects = null;

	let back = () => sys.ubusd_pid() != null && (objects = sys.objects()) != null && (!(PROCD in before) || (PROCD in objects));

	if (!wait_for(sys, back)) {
		push(problems, (objects == null)
			? `ubusd did not start again within ${RETURN_SECONDS} s: reboot`
			: `procd did not register on ubus again within ${RETURN_SECONDS} s: reboot`);
		return { ok: false, made, problems };
	}

	for (let object, service in REREGISTER) {
		if (!(object in before) || (object in objects))
			continue;
		if (sys.restart(service))
			push(made, `restarted ${service}, which does not register on ubus again by itself`);
		else
			push(problems, `cannot restart ${service}, which does not register on ubus again by itself`);
	}

	let gone = () => filter(before, (o) => !(o in (sys.objects() ?? [])));

	wait_for(sys, () => !length(gone()));

	let missing = gone();

	if (length(missing))
		push(problems, `not on ubus again: ${join(' ', missing)}: restart the services that register them, or reboot`);

	return { ok: !length(missing), made, problems };
};

/**
 * The system reload() acts on: ubusd's process from /proc, ubus's objects over `connect`, the services' init scripts.
 *
 * @param {Object} fs fs's lsdir, readfile and stat.
 * @param {function(?string, int): ?Object} connect ubus's connect(socket, timeout).
 * @returns {UbusdSys} the system.
 */
export function host(fs, connect) {
	return {
		ubusd_pid: function() {
			for (let p in fs.lsdir('/proc') ?? [])
				if (match(p, /^[0-9]+$/) && trim(fs.readfile(`/proc/${p}/comm`) ?? '') == 'ubusd')
					return +p;
			return null;
		},
		alive: function(pid) {
			let st = fs.readfile(`/proc/${pid}/stat`);

			return st != null && substr(split(st, ') ')[1] ?? 'Z', 0, 1) != 'Z';
		},
		signal: (pid) => system([ 'kill', '-HUP', `${pid}` ]) == 0,
		objects: function() {
			let c = connect(null, 3);
			let list = c?.list();

			c?.disconnect();
			return (type(list) == 'array') ? filter(list, (o) => type(o) == 'string') : null;
		},
		restart: function(service) {
			let script = `/etc/init.d/${service}`;

			return fs.stat(script)?.type == 'file' && system([ script, 'restart' ]) == 0;
		},
		sleep: (ms) => sleep(ms),
	};
};
