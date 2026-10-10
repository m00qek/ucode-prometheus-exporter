'use strict';

import { Result, errors, services } from 'prometheus.exporter';

export const SOCKET = '/var/run/chrony/chronyd.sock';

export const meta = {
	name: 'chrony',
	title: 'chrony NTP daemon',
	help: 'chronyd\'s tracking and sources, and its server statistics where it serves time, from chronyc.',
	needs: [ 'ubus', 'uci', 'fs', 'exec' ],
	ubus: { rc: [ 'list' ] },
	configs: [ 'chrony' ],
	commands: [ 'chronyc' ],
	optional_commands: [ 'chronyc' ],
};

const LOCAL_ADDRESS = '127.127.1.1';
const LOCAL_REFID = '4C4F434C';

const MODES = { '^': 'client', '=': 'peer', '#': 'reference clock' };
const STATES = { '*': 'sync', '?': 'unreach', 'x': 'falseticker', '~': 'jittery', '+': 'candidate', '-': 'outlier' };

const NO_SAMPLE = 4294967295;

const TRACKING = [
	[ 5, 'chrony_tracking_last_offset_seconds', 'gauge', 'Chrony tracking last offset in seconds' ],
	[ 3, 'chrony_tracking_reference_timestamp_seconds', 'gauge', 'Chrony tracking Reference timestamp' ],
	[ 4, 'chrony_tracking_system_time_seconds', 'gauge', 'Chrony tracking System time' ],
	[ null, 'chrony_tracking_remote_reference', 'gauge', 'Chrony tracking is connected to a remote source' ],
	[ 6, 'chrony_tracking_rms_offset_seconds', 'gauge', 'Chrony tracking long-term average of the offset' ],
	[ 10, 'chrony_tracking_root_delay_seconds', 'gauge', 'This is the total of the network path delays to the stratum-1 computer from which the computer is ultimately synchronised' ],
	[ 11, 'chrony_tracking_root_dispersion_seconds', 'gauge', 'Chrony tracking total of all measurement errors to the NTP root' ],
	[ 7, 'chrony_tracking_frequency_ppms', 'gauge', 'Rate by which the system\'s clock would be wrong if chronyd was not correcting it, in PPMs' ],
	[ 8, 'chrony_tracking_residual_frequency_ppms', 'gauge', 'For the currently selected reference source, the difference between the frequency it suggests and the one currently in use, in PPMs' ],
	[ 9, 'chrony_tracking_skew_ppms', 'gauge', 'The estimated error bound on the frequency, in PPMs' ],
	[ 12, 'chrony_tracking_update_interval_seconds', 'gauge', 'The time elapsed since the last measurement from the reference source was processed, in seconds' ],
	[ 2, 'chrony_tracking_stratum', 'gauge', 'Chrony tracking client stratum' ],
];

const SERVERSTATS = [
	[ 0, 'chrony_serverstats_ntp_packets_received_total', 'counter', 'The number of valid NTP requests received by the server.' ],
	[ 5, 'chrony_serverstats_nts_ke_connections_accepted_total', 'counter', 'The number of NTS-KE connections accepted by the server.' ],
	[ 2, 'chrony_serverstats_command_packets_received_total', 'counter', 'The number of command requests received by the server.' ],
	[ 1, 'chrony_serverstats_ntp_packets_dropped_total', 'counter', 'The number of NTP requests dropped by the server due to rate limiting.' ],
	[ 6, 'chrony_serverstats_nts_ke_connections_dropped_total', 'counter', 'The number of NTS-KE connections dropped by the server due to rate limiting.' ],
	[ 3, 'chrony_serverstats_command_packets_dropped_total', 'counter', 'The number of command requests dropped by the server due to rate limiting.' ],
	[ 4, 'chrony_serverstats_client_log_records_dropped_total', 'counter', 'The number of client log records dropped by the server to limit the memory use.' ],
	[ 7, 'chrony_serverstats_authenticated_ntp_packets_total', 'counter', 'The number of received NTP requests that were authenticated (with a symmetric key or NTS).' ],
	[ 8, 'chrony_serverstats_interleaved_ntp_packets_total', 'counter', 'The number of received NTP requests that were detected to be in the interleaved mode.' ],
	[ 9, 'chrony_serverstats_ntp_timestamps_held', 'gauge', 'The number of pairs of receive and transmit timestamps that the server is currently holding in memory for clients using the interleaved mode.' ],
	[ 10, 'chrony_serverstats_ntp_timestamp_span_seconds', 'gauge', 'The interval (in seconds) covered by the currently held NTP timestamps.' ],
	[ 11, 'chrony_serverstats_ntp_daemon_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the daemon.' ],
	[ 12, 'chrony_serverstats_ntp_daemon_tx_timestamps_total', 'counter', 'The number of NTP responses which included a transmit timestamp captured by the daemon.' ],
	[ 13, 'chrony_serverstats_ntp_kernel_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the kernel.' ],
	[ 14, 'chrony_serverstats_ntp_kernel_tx_timestamps_total', 'counter', 'The number of NTP responses (in the interleaved mode) which included a transmit timestamp captured by the kernel.' ],
	[ 15, 'chrony_serverstats_ntp_hw_rx_timestamps_total', 'counter', 'The number of NTP responses which included a receive timestamp captured by the NIC.' ],
	[ 16, 'chrony_serverstats_ntp_hw_tx_timestamps_total', 'counter', 'The number of NTP responses (in the interleaved mode) which included a transmit timestamp captured by the NIC.' ],
];

function number(s) {
	let n = (type(s) == 'string' && s != '') ? +s : null;

	return (n != null && n == n) ? n : null;
}

function rows(text) {
	return map(filter(split(text ?? '', '\n'), length), (l) => split(l, ','));
}

export function argv(report) {
	return [ 'chronyc', '-u', 'root', '-c', report ];
};

function run(deps, report) {
	let res = deps.exec.run(argv(report));

	return res.ok ? Result.ok(rows(res.data)) : res;
}

function invalid(report, msg) {
	return Result.err(errors.SOURCE_INVALID, `chronyc -c ${report}: ${msg}`);
}

function reachability(octal) {
	let n = 0;

	for (let i = 0; i < length(octal); i++) {
		let d = ord(octal, i) - 48;

		if (d < 0 || d > 7)
			return null;
		n = n * 8 + d;
	}

	let reached = 0;
	for (let bits = n & 0xff; bits; bits >>= 1)
		reached += bits & 1;

	return [ reached / 8.0, n & 1 ];
}

function pow2(e) {
	let v = 1.0;

	for (let i = 0; i < e; i++)
		v *= 2;
	for (let i = 0; i > e; i--)
		v /= 2;

	return v;
}

function tracking(out, f) {
	if (length(f) < 14)
		return `${length(f)} fields, not 14`;
	if (number(f[2]) == null)
		return `stratum ${sprintf('%J', f[2])} is not a number`;

	out.gauge('chrony_tracking_info', 'Chrony tracking info')(
		{ tracking_address: f[1], tracking_name: f[1], tracking_refid: f[0] }, 1);

	let remote = (f[1] == LOCAL_ADDRESS || f[0] == LOCAL_REFID) ? 0 : 1;

	for (let t in TRACKING)
		out[t[2]](t[1], t[3])(null, t[0] == null ? remote : f[t[0]]);

	return null;
}

function sources(out, list) {
	let fam = {
		age: out.gauge('chrony_sources_last_sample_age_seconds', 'Chrony sources last good sample age in seconds'),
		ratio: out.gauge('chrony_sources_reachability_ratio', 'Chrony sources ratio of packet reachability'),
		success: out.gauge('chrony_sources_reachability_success', 'Chrony sources last poll reachability success'),
		offset: out.gauge('chrony_sources_last_sample_offset_seconds', 'Chrony sources last sample offset in seconds'),
		error: out.gauge('chrony_sources_last_sample_error_margin_seconds', 'Chrony sources last sample margin of error in seconds'),
		poll: out.gauge('chrony_sources_polling_interval_seconds', 'Chrony sources polling interval in seconds'),
		state: out.gauge('chrony_sources_state_info', 'Chrony sources state info'),
		stratum: out.gauge('chrony_sources_stratum', 'Chrony sources stratum'),
	};

	for (let i, f in list) {
		if (length(f) < 10)
			return `line ${i + 1}: ${length(f)} fields, not 10`;

		let reach = reachability(f[5]);
		let poll = number(f[4]);
		if (!reach || type(poll) != 'int')
			return `line ${i + 1}: ${sprintf('%J', join(',', f))}`;

		let address = f[2];
		let labels = out.labels({ source_address: address, source_name: address });
		let age = number(f[6]);

		if (age != null && age != NO_SAMPLE)
			fam.age(labels, age);
		fam.ratio(labels, reach[0]);
		fam.success(labels, reach[1]);
		fam.offset(labels, f[7]);
		fam.error(labels, f[9]);
		fam.poll(labels, pow2(poll));
		fam.state({ source_address: address, source_name: address,
			source_state: STATES[f[1]] ?? 'unknown', source_mode: MODES[f[0]] ?? 'unknown' }, 1);
		fam.stratum(labels, f[3]);
	}

	return null;
}

function serverstats(out, f) {
	for (let s in SERVERSTATS)
		if (s[0] < length(f))
			out[s[2]](s[1], s[3])(null, f[s[0]]);
}

function serves(uci) {
	return length(uci.chrony.sections('allow')) > 0;
}

export function collect(deps, out) {
	let res = run(deps, 'tracking');

	if (!res.ok)
		return services.unless_disabled(deps.ubus, 'chronyd', res);
	if (length(res.data) != 1)
		return invalid('tracking', `${length(res.data)} lines, not 1`);

	let why = tracking(out, res.data[0]);
	if (why)
		return invalid('tracking', why);

	res = run(deps, 'sources');
	if (!res.ok)
		return res;

	why = sources(out, res.data);
	if (why)
		return invalid('sources', why);

	if (!serves(deps.uci) || deps.fs.stat(SOCKET) == null)
		return Result.ok();

	res = run(deps, 'serverstats');
	if (!res.ok)
		return res;
	if (length(res.data) != 1)
		return invalid('serverstats', `${length(res.data)} lines, not 1`);

	serverstats(out, res.data[0]);

	return Result.ok();
};
