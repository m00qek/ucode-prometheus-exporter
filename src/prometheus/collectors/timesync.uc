'use strict';

import { Result, errors, services } from 'prometheus.exporter';

export const STATE_DIR = '/var/run/prometheus-exporter/timesync';
export const NTPD_STATE = `${STATE_DIR}/ntpd`;

export const meta = {
	name: 'timesync',
	title: 'Time synchronization',
	help: 'Whether busybox ntpd or chronyd keeps the clock synchronized: stratum, offset and last update.',
	needs: [ 'ubus', 'fs', 'exec' ],
	ubus: { 'prometheus-exporter': [ 'time_daemons' ], rc: [ 'list' ] },
	commands: [ 'chronyc' ],
	optional_commands: [ 'chronyc' ],
	paths: [ { path: STATE_DIR, owned: true } ],
};

const MAXSTRAT = 16;

export const CHRONYC_TRACKING = [ 'chronyc', '-u', 'root', '-c', 'tracking' ];

const UNSYNCHRONISED = 'Not synchronised';

function running(ubus) {
	let res = ubus.call('prometheus-exporter', 'time_daemons');

	if (!res.ok)
		return res;

	let r = res.data?.running;
	if (type(r) != 'object')
		return Result.err(errors.SOURCE_INVALID, `prometheus-exporter time_daemons: ${res.data?.message ?? 'no running'}`);

	return Result.ok({ ntpd: r.sysntpd === true, chronyd: r.chronyd === true });
}

function number(s) {
	let n = (type(s) == 'string' && s != '') ? +s : null;

	return (n != null && n == n) ? n : null;
}

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

function ntpd(deps) {
	let text = deps.fs.readfile(NTPD_STATE);

	if (text == null)
		return { synchronized: false };

	let s = parse_state(text);
	if (type(s) == 'string')
		return Result.err(errors.SOURCE_INVALID, `${NTPD_STATE}: ${s}`);

	return { synchronized: s.stratum < MAXSTRAT, stratum: s.stratum, offset: s.offset, updated: s.time };
}

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
	let runs = running(deps.ubus);
	if (!runs.ok)
		return runs;

	let ntpd_runs = runs.data.ntpd, chronyd_runs = runs.data.chronyd;
	let failure = null;
	if (!chronyd_runs)
		failure = services.unless_disabled(deps.ubus, 'chronyd',
			Result.err(errors.SOURCE_UNREADABLE, 'chronyd is enabled and not running'));

	if (!ntpd_runs && !chronyd_runs)
		return Result.is_none(failure) ? Result.none('neither ntpd nor chronyd runs') : failure;

	let synchronized = out.gauge('node_timesync_synchronized', 'Whether the NTP daemon has synchronized the clock (1) or not (0).');
	let stratum = out.gauge('node_timesync_stratum', 'The stratum of the clock, while it is synchronized.');
	let offset = out.gauge('node_timesync_offset_seconds', 'The offset of the clock from the daemon\'s reference at its last update, in seconds.');
	let updated = out.gauge('node_timesync_last_update_timestamp_seconds', 'When the daemon last updated the clock (chronyd) or reported on it (busybox ntpd).');

	if (Result.is_none(failure))
		failure = null;

	for (let d in [ [ 'chronyd', chronyd_runs, chronyd ], [ 'ntpd', ntpd_runs, ntpd ] ]) {
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
