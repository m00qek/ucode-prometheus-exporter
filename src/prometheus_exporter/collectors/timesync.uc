'use strict';

// Is the clock synchronized? Whichever NTP daemon keeps it: busybox's ntpd
// (sysntpd, OpenWrt's default) or chronyd, each that runs with its name as
// the `daemon` label.
//
// A daemon runs when procd runs its instance (`ubus call service list`):
// sysntpd's init script is enabled on every image and starts ntpd only when
// /etc/config/system says so (LuCI's "Enable NTP client"), so its instance
// is what says whether busybox ntpd keeps the clock. With neither running
// there is nothing to observe. chronyd enabled and not running (rpcd's rc,
// asked only then) fails the collector, as any service enabled that does not
// answer.
//
// - busybox ntpd has no interface to ask. It runs /usr/sbin/ntpd-hotplug on
//   each event (a step, a new stratum, a loss of sync, and periodically,
//   every 11 minutes or more), which hands procd's hotplug.ntp its
//   environment; the base package's /etc/hotplug.d/ntp/90-prometheus-exporter
//   keeps the last event in NTPD_STATE. Synchronized is a stratum below 16,
//   busybox's MAXSTRAT; the offset is the event's (of the last update, for a
//   periodic one), and its time is when ntpd last reported. Until ntpd's
//   first event since boot (or since the package was installed), it is not
//   known to be synchronized: 0.
// - chronyd answers `chronyc -c tracking`: synchronized unless its leap status
//   is "Not synchronised", its stratum, the last offset and the reference
//   time, when that measurement was used. chronyc is one of
//   meta.optional_commands: it is there only where chrony is installed. It
//   runs as root (-u root): OpenWrt builds it to drop root for the chrony
//   user, whom the jail, without /etc/passwd, cannot look up. The chrony
//   collector has chronyd's details.
//
// The stratum, offset and time of the last update are written only while the
// daemon is synchronized: an unsynchronized daemon's are 0 or meaningless.
// node_exporter's timex collector reads the kernel's adjtimex(2) state, which
// ucode cannot ask; these are the daemon's, so they are named apart.

import { Result, errors, services } from 'prometheus_exporter.api';

// Where the hotplug script keeps busybox ntpd's last event: in the service's
// run directory, beside the exporter's own state, which is the uhttpd
// instance's and goes with it, where this is written from outside and
// outlives a restart. The jail mounts the directory, read-only: the script
// renames a new file into it, which a mount of the file itself would not
// show. It is this collector's own path, declared in meta.paths like any
// other: the script and this collector name it, and a test holds both to the
// run directory prometheus_exporter.state keeps, which is the core's.
export const STATE_DIR = '/var/run/prometheus-exporter/timesync';
export const NTPD_STATE = `${STATE_DIR}/ntpd`;

export const meta = {
	name: 'timesync',
	title: 'Time synchronization',
	help: 'Whether busybox ntpd or chronyd keeps the clock synchronized: stratum, offset and last update.',
	needs: [ 'ubus', 'fs', 'exec' ],
	ubus: { service: [ 'list' ], rc: [ 'list' ] },
	commands: [ 'chronyc' ],
	optional_commands: [ 'chronyc' ],
	paths: [ { path: STATE_DIR, owned: true } ],
};

// busybox ntpd's stratum while it is not synchronized (MAXSTRAT, ntpd.c).
const MAXSTRAT = 16;

// chronyc's report of what chronyd tracks, as CSV, run as the jail's root.
export const CHRONYC_TRACKING = [ 'chronyc', '-u', 'root', '-c', 'tracking' ];

// chronyc's leap status of an unsynchronized chronyd (client.c, print_report).
const UNSYNCHRONISED = 'Not synchronised';

// The program of each daemon's instance, among a service's instances (chronyd
// also has one that waits for its first sync, and exits).
const DAEMONS = { sysntpd: '/usr/sbin/ntpd', chronyd: '/usr/sbin/chronyd' };

// Whether procd runs the daemon of service `name`, as a Result.
function running(ubus, name) {
	let res = ubus.call('service', 'list', { name });

	if (!res.ok)
		return res;

	for (let n, i in res.data?.[name]?.instances ?? {})
		if (i?.running === true && i.command?.[0] == DAEMONS[name])
			return Result.ok(true);

	return Result.ok(false);
}

// A number spelled as a string, or null.
function number(s) {
	let n = (type(s) == 'string' && s != '') ? +s : null;

	return (n != null && n == n) ? n : null;
}

// The hotplug script's file: { time, action, stratum, offset, ... } as
// numbers where they are, or a string saying what is wrong with it.
export function parse_state(text) {
	let state = {};

	for (let line in split(text, '\n')) {
		let i = index(line, '=');

		if (i > 0)
			state[substr(line, 0, i)] = substr(line, i + 1);
	}

	for (let k in [ 'time', 'stratum', 'offset' ]) {
		let v = number(state[k]);

		if (v == null)
			return `${k} is ${sprintf('%J', state[k])}, not a number`;
		state[k] = v;
	}

	return state;
};

// { synchronized, stratum, offset, updated } of busybox ntpd.
function ntpd(deps) {
	let text = deps.fs.readfile(NTPD_STATE);

	if (text == null)
		return { synchronized: false };

	let s = parse_state(text);
	if (type(s) == 'string')
		return Result.err(errors.SOURCE_INVALID, `${NTPD_STATE}: ${s}`);

	return { synchronized: s.stratum < MAXSTRAT, stratum: s.stratum, offset: s.offset, updated: s.time };
}

// The fields of `chronyc -c tracking`, chrony 4.x: reference ID, name or
// address, stratum, reference time, system time, last offset, RMS offset,
// frequency, residual frequency, skew, root delay, root dispersion, update
// interval, leap status.
export function parse_tracking(text) {
	let f = split(trim(text ?? ''), ',');

	if (length(f) < 14)
		return `${length(f)} fields, not 14`;

	for (let i in [ 2, 3, 5 ])
		if (number(f[i]) == null)
			return `field ${i + 1} is ${sprintf('%J', f[i])}, not a number`;

	return { refid: f[0], name: f[1], stratum: +f[2], ref_time: +f[3], system_time: f[4], last_offset: +f[5],
		rms_offset: f[6], frequency: f[7], residual_frequency: f[8], skew: f[9], root_delay: f[10],
		root_dispersion: f[11], update_interval: f[12], leap: f[13] };
};

// { synchronized, stratum, offset, updated } of chronyd.
function chronyd(deps) {
	let res = deps.exec.run(CHRONYC_TRACKING);

	if (!res.ok)
		return res;

	let t = parse_tracking(res.data);
	if (type(t) == 'string')
		return Result.err(errors.SOURCE_INVALID, `chronyc -c tracking: ${t}`);

	return { synchronized: t.leap != UNSYNCHRONISED, stratum: t.stratum, offset: t.last_offset, updated: t.ref_time };
}

export function collect(deps, out) {
	let ntpd_runs = running(deps.ubus, 'sysntpd');
	if (!ntpd_runs.ok)
		return ntpd_runs;

	let chronyd_runs = running(deps.ubus, 'chronyd');
	if (!chronyd_runs.ok)
		return chronyd_runs;

	// chronyd enabled and not running is a failure; sysntpd's instance is not
	// there while /etc/config/system turns NTP off, which is no failure.
	let failure = null;
	if (!chronyd_runs.data)
		failure = services.unless_disabled(deps.ubus, 'chronyd',
			Result.err(errors.SOURCE_UNREADABLE, 'chronyd is enabled and not running'));

	if (!ntpd_runs.data && !chronyd_runs.data)
		return Result.is_none(failure) ? Result.none('neither ntpd nor chronyd runs') : failure;

	let synchronized = out.gauge('node_timesync_synchronized', 'Whether the NTP daemon has synchronized the clock (1) or not (0).');
	let stratum = out.gauge('node_timesync_stratum', 'The stratum of the clock, while it is synchronized.');
	let offset = out.gauge('node_timesync_offset_seconds', 'The offset of the clock from the daemon\'s reference at its last update, in seconds.');
	let updated = out.gauge('node_timesync_last_update_timestamp_seconds', 'When the daemon last updated the clock (chronyd) or reported on it (busybox ntpd).');

	if (Result.is_none(failure))
		failure = null;

	for (let d in [ [ 'chronyd', chronyd_runs.data, chronyd ], [ 'ntpd', ntpd_runs.data, ntpd ] ]) {
		if (!d[1])
			continue;

		let s = d[2](deps);
		if (Result.is(s)) {
			failure ??= s;
			continue;
		}

		let labels = { daemon: d[0] };

		synchronized(labels, s.synchronized);
		if (!s.synchronized)
			continue;

		stratum(labels, s.stratum);
		offset(labels, s.offset);
		updated(labels, s.updated);
	}

	return failure ?? Result.ok();
};
